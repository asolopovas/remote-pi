import { randomBytes, randomUUID, scrypt, timingSafeEqual } from "node:crypto";
import { launchStoreDir, readPrivateJson, writePrivateJson, withLaunchStoreLock, launchPinAbsent, createPrivatePin } from "./launch_store.js";
import type { LauncherStatus, SessionControlAccess } from "../protocol/types.js";
interface PinRecord { version: 1; salt: string; verifier: string; failures: number; blockedUntil: number }
const derive = (pin: string, salt: Buffer): Promise<Buffer> => new Promise((ok, fail) => scrypt(pin, salt, 32, { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }, (err, key) => err ? fail(err) : ok(key)));
export const validPin = (pin: string) => /^\d{6,12}$/.test(pin);
export async function setupLaunchPin(pin: string, dir = launchStoreDir()): Promise<void> {
  if (!validPin(pin)) throw new Error("Use 6–12 digits; no default PIN exists");
  const salt = randomBytes(32);
  const verifier = await derive(pin, salt);
  await withLaunchStoreLock(dir, () => writePrivateJson(dir, "pin.json", { version: 1, salt: salt.toString("hex"), verifier: verifier.toString("hex"), failures: 0, blockedUntil: 0 }));
  verifier.fill(0);
}
/** In-memory grants are never restored. The epoch is a one-use unlock challenge and
 * authority generation, not a secret; authenticated pairing remains mandatory. */
export class LaunchSecurity {
  epoch = randomUUID();
  private grants = new Map<string, { expires: number; fingerprint: string }>();
  private busy = false;
  private used = new Set<string>();
  constructor(readonly launcherId: string, readonly dir = launchStoreDir(), private readonly now = Date.now, readonly ttlMs = 5 * 60_000, private readonly derivePin = derive) {}
  private async record(): Promise<PinRecord> {
    const r = await readPrivateJson<PinRecord>(this.dir, "pin.json");
    if (r.version !== 1 || !/^[a-f0-9]{64}$/.test(r.salt) || !/^[a-f0-9]{64}$/.test(r.verifier) || !Number.isSafeInteger(r.failures) || r.failures < 0 || !Number.isSafeInteger(r.blockedUntil) || r.blockedUntil < 0) throw new Error("PIN setup unavailable");
    return r;
  }
  lock(): void { this.epoch = randomUUID(); this.grants.clear(); }
  async status(owner: string): Promise<LauncherStatus> {
    let record: PinRecord | undefined;
    let pin_setup: NonNullable<LauncherStatus["pin_setup"]> = "unavailable";
    try {
      if (await launchPinAbsent(this.dir)) pin_setup = "available";
      else { record = await this.record(); pin_setup = "configured"; }
    } catch { this.lock(); }
    const grant = this.grants.get(owner);
    const expires = record && grant?.fingerprint === record.salt + record.verifier ? grant.expires : 0;
    return { launcher_api: 3, launcher_id: this.launcherId, epoch: this.epoch, configured: !!record, pin_setup, unlocked: !!record && expires > this.now(), expires_at: expires > this.now() ? expires : null, cooldown_until: record?.blockedUntil ?? 0 };
  }
  /** Retained grants are evidence of expiry; process age never is. Lock clears it. */
  access(owner: string, epoch: string): SessionControlAccess {
    if (epoch !== this.epoch) return { state: "unavailable", expires_at: null };
    const grant = this.grants.get(owner);
    if (!grant) return { state: "locked", expires_at: null };
    return { state: grant.expires > this.now() ? "unlocked" : "expired", expires_at: grant.expires };
  }
  hasGrant(owner: string, epoch: string): boolean { return epoch === this.epoch && (this.grants.get(owner)?.expires ?? 0) > this.now(); }
  async authorized(owner: string, epoch: string): Promise<boolean> {
    if (epoch !== this.epoch || (this.grants.get(owner)?.expires ?? 0) <= this.now()) return false;
    try { const record = await this.record(); if (this.grants.get(owner)?.fingerprint !== record.salt + record.verifier) { this.lock(); return false; } } catch { this.lock(); return false; }
    return epoch === this.epoch && (this.grants.get(owner)?.expires ?? 0) > this.now();
  }
  async initialize(owner: string, id: string, launcher: string, epoch: string, pin: string, paired: () => Promise<boolean>, isCurrent: () => boolean = () => true): Promise<void> {
    // Shared, non-evicting credential budget and single-flight with unlock. Store IDs only.
    if (this.busy || launcher !== this.launcherId || epoch !== this.epoch || this.used.has(id) || this.used.size >= 256 || !validPin(pin)) throw new Error("Stale, duplicate, busy or invalid credential request");
    this.used.add(id); this.busy = true;
    const current = () => { if (epoch !== this.epoch || !isCurrent()) throw new Error("Authority changed"); };
    const authorize = async () => { current(); if (!await paired()) throw new Error("Authority changed"); current(); };
    let fingerprint = "";
    try {
      await withLaunchStoreLock(this.dir, async () => {
        await authorize();
        if (!await launchPinAbsent(this.dir)) throw new Error("PIN initialization unavailable");
        const salt = randomBytes(32);
        const key = await this.derivePin(pin, salt);
        try {
          await authorize();
          await createPrivatePin(this.dir, { version: 1, salt: salt.toString("hex"), verifier: key.toString("hex"), failures: 0, blockedUntil: 0 }, authorize, current);
          fingerprint = salt.toString("hex") + key.toString("hex");
        } finally { key.fill(0); }
      });
      // Publication includes fsync, staging cleanup AND transaction-lock release.
      // A concurrent Lock/revoke must win even during the last asynchronous step.
      await authorize();
      current();
      this.lock();
      this.grants.set(owner, { expires: this.now() + this.ttlMs, fingerprint });
    } finally { this.busy = false; }
  }
  async unlock(owner: string, id: string, launcher: string, epoch: string, pin: string, paired: () => Promise<boolean>): Promise<void> {
    if (this.busy || launcher !== this.launcherId || epoch !== this.epoch || this.used.has(id) || this.used.size >= 256 || !validPin(pin)) throw new Error("Stale, duplicate, busy or invalid unlock request");
    this.used.add(id); this.busy = true;
    try {
      await withLaunchStoreLock(this.dir, async () => {
      const record = await this.record();
      if (epoch !== this.epoch || !await paired() || epoch !== this.epoch) throw new Error("Authority changed");
      if (record.blockedUntil > this.now()) throw new Error("PIN cooldown active");
      const key = await this.derivePin(pin, Buffer.from(record.salt, "hex"));
      const matches = timingSafeEqual(key, Buffer.from(record.verifier, "hex")); key.fill(0);
      record.failures = matches ? 0 : Math.min(record.failures + 1, 100);
      record.blockedUntil = matches ? 0 : this.now() + Math.min(300_000, 1000 * 2 ** Math.min(record.failures, 9));
      await writePrivateJson(this.dir, "pin.json", record);
      if (!matches) throw new Error("PIN rejected");
      if (!await paired() || epoch !== this.epoch) throw new Error("Authority changed");
      this.grants.set(owner, { expires: this.now() + this.ttlMs, fingerprint: record.salt + record.verifier });
      // Invalidate pending unlock requests, while retaining other owners' grants.
      this.epoch = randomUUID();
      });
    } finally { this.busy = false; }
  }
}
