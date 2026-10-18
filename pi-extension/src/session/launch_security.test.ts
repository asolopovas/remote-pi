import { test, expect } from "vitest";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import { resolve, join } from "node:path";
import { tmpdir } from "node:os";
import { LaunchSecurity, setupLaunchPin } from "./launch_security.js";
import { readPrivateJson } from "./launch_store.js";

test("PIN absent, cooldown persists across launchers, reset, owner/epoch/expiry/restart gates", async () => {
  const dir = await mkdtemp(join(tmpdir(), "launch-pin-")); let now = 1000;
  const a = new LaunchSecurity("launcher-a", dir, () => now, 100);
  const b = new LaunchSecurity("launcher-b", dir, () => now, 100);
  try {
    expect((await a.status("owner-a")).configured).toBe(false);
    await expect(a.unlock("owner-a", "absent", a.launcherId, a.epoch, "123456", async () => true)).rejects.toThrow();
    await setupLaunchPin("654321", dir);
    expect((await stat(join(dir, "pin.json"))).mode & 0o777).toBe(0o600);
    await Promise.allSettled([a, b].map((s, i) => s.unlock("owner-a", "wrong-" + i, s.launcherId, s.epoch, "000000", async () => true)));
    const record = await readPrivateJson<{ failures: number; blockedUntil: number }>(dir, "pin.json");
    expect(record.failures).toBe(1); expect(record.blockedUntil).toBeGreaterThan(now);
    await expect(a.unlock("owner-a", "cooldown", a.launcherId, a.epoch, "654321", async () => true)).rejects.toThrow("cooldown");
    now = record.blockedUntil + 1;
    const oldEpoch = a.epoch;
    await a.unlock("owner-a", "good", a.launcherId, oldEpoch, "654321", async () => true);
    expect(await a.authorized("owner-a", oldEpoch)).toBe(false);
    expect(await a.authorized("owner-a", a.epoch)).toBe(true);
    expect(await a.authorized("owner-b", a.epoch)).toBe(false);
    expect(await b.authorized("owner-a", b.epoch)).toBe(false);
    await expect(a.unlock("owner-a", "good", a.launcherId, a.epoch, "654321", async () => true)).rejects.toThrow();
    await a.unlock("owner-b", "owner-b-good", a.launcherId, a.epoch, "654321", async () => true);
    expect(await a.authorized("owner-a", a.epoch)).toBe(true);
    expect(await a.authorized("owner-b", a.epoch)).toBe(true);
    now += 101; expect(await a.authorized("owner-a", a.epoch)).toBe(false);
    await a.unlock("owner-a", "new-good", a.launcherId, a.epoch, "654321", async () => true);
    await setupLaunchPin("111111", dir);
    expect(await a.authorized("owner-a", a.epoch)).toBe(false);
    const restarted = new LaunchSecurity("new-incarnation", dir);
    expect((await restarted.status("owner-a")).unlocked).toBe(false);
    await expect(restarted.unlock("owner-a", "stale-host", a.launcherId, restarted.epoch, "111111", async () => true)).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("Lock and owner revocation invalidate in-flight slow unlock before grant", async () => {
  const dir = await mkdtemp(join(tmpdir(), "launch-pin-race-"));
  try {
    await setupLaunchPin("654321", dir);
    const security = new LaunchSecurity("host", dir);
    let release!: () => void; const waiting = new Promise<void>(r => { release = r; });
    let entered!: () => void; const admission = new Promise<void>(r => { entered = r; });
    const unlock = security.unlock("owner", "race", "host", security.epoch, "654321", async () => { entered(); await waiting; return true; });
    await admission; security.lock(); release();
    await expect(unlock).rejects.toThrow("Authority changed");
    expect((await security.status("owner")).unlocked).toBe(false);
    await expect(security.unlock("owner", "revoked", "host", security.epoch, "654321", async () => false)).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});


test("separate host processes serialize shared cooldown and never overwrite concurrent PIN reset", async () => {
  const dir = await mkdtemp(join(tmpdir(), "launch-pin-processes-"));
  try {
    await setupLaunchPin("654321", dir);
    const code = `import {LaunchSecurity} from ${JSON.stringify("file://" + resolve("dist/session/launch_security.js"))}; let input=''; for await(const b of process.stdin) input+=b; const request=JSON.parse(input); const s=new LaunchSecurity(request.launcher,request.dir); try { await s.unlock('owner',request.id,s.launcherId,s.epoch,request.pin,async()=>true); process.exitCode=1; } catch { process.exitCode=0; }`;
    const attempt = (index: number) => new Promise<number | null>((ok, fail) => {
      const child = spawn(process.execPath, ["--input-type=module", "-e", code], { stdio: ["pipe", "ignore", "pipe"] });
      child.stderr.on("data", () => {}); child.once("exit", ok); child.once("error", fail);
      child.stdin.end(JSON.stringify({ launcher: "process-" + index, id: "wrong-" + index, dir, pin: "000000" }));
    });
    expect(await Promise.all([attempt(1), attempt(2)])).toEqual([0, 0]);
    const record = await readPrivateJson<{ failures: number; blockedUntil: number }>(dir, "pin.json");
    expect(record.failures).toBe(1); expect(record.blockedUntil).toBeGreaterThan(Date.now());
    const s = new LaunchSecurity("parent", dir, () => record.blockedUntil + 1);
    let release!: () => void; let entered!: () => void;
    const waiting = new Promise<void>(r => { release = r; }); const admission = new Promise<void>(r => { entered = r; });
    const unlocking = s.unlock("owner", "reset-race", s.launcherId, s.epoch, "654321", async () => { entered(); await waiting; return true; });
    await admission; const reset = setupLaunchPin("111111", dir); release();
    await Promise.all([unlocking, reset]);
    expect(await s.authorized("owner", s.epoch)).toBe(false);
    const fresh = new LaunchSecurity("new", dir);
    await fresh.unlock("owner", "new-pin", fresh.launcherId, fresh.epoch, "111111", async () => true);
    expect(await fresh.authorized("owner", fresh.epoch)).toBe(true);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
