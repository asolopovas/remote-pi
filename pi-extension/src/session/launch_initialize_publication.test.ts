import { test, expect, vi } from "vitest";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
const hooks = vi.hoisted(() => ({ published: undefined as (() => void) | undefined }));
vi.mock("node:fs/promises", async importOriginal => {
  const fs = await importOriginal<typeof import("node:fs/promises")>();
  return { ...fs, rmdir: async (...args: Parameters<typeof fs.rmdir>) => {
    const result = await fs.rmdir(...args);
    if (String(args[0]).endsWith("/transaction.lock")) hooks.published?.();
    return result;
  } };
});
import { LaunchSecurity, setupLaunchPin } from "./launch_security.js";

test.each(["Lock", "pairing", "channel", "lifecycle"])("%s in final asynchronous publication leaves configured but locked, without rollback", async change => {
  const dir = await mkdtemp(join(tmpdir(), "pin-final-publication-"));
  let paired = true, current = true;
  const s = new LaunchSecurity("host", dir);
  const epoch = s.epoch;
  let lockEpoch: string | undefined;
  try {
    hooks.published = () => {
      if (change === "Lock") { s.lock(); lockEpoch = s.epoch; }
      else if (change === "pairing") paired = false;
      else current = false;
    };
    await expect(s.initialize("owner", "init", "host", epoch, "654321", async () => paired, () => current)).rejects.toThrow("Authority changed");
    hooks.published = undefined;
    const record = await readFile(join(dir, "pin.json"), "utf8");
    expect(await s.status("owner")).toMatchObject({ configured: true, unlocked: false });
    expect((await s.status("other-owner")).unlocked).toBe(false);
    if (change === "Lock") { expect(s.epoch).not.toBe(epoch); expect(s.epoch).toBe(lockEpoch); }
    await expect(s.initialize("owner", "retry", "host", s.epoch, "111111", async () => true)).rejects.toThrow();
    expect(await readFile(join(dir, "pin.json"), "utf8")).toBe(record);
  } finally { hooks.published = undefined; await rm(dir, { recursive: true, force: true }); }
});

test("initialization grant is initiating Owner only, current epoch, expiring and verifier-bound", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pin-initial-grant-"));
  let now = 1000;
  const s = new LaunchSecurity("host", dir, () => now, 100);
  try {
    const epoch = s.epoch;
    await s.initialize("owner", "init", "host", epoch, "654321", async () => true);
    expect(await s.status("owner")).toMatchObject({ launcher_api: 3, unlocked: true, expires_at: 1100 });
    expect(await s.authorized("owner", epoch)).toBe(false);
    expect(await s.authorized("owner", s.epoch)).toBe(true);
    expect(await s.authorized("other-owner", s.epoch)).toBe(false);
    await expect(s.initialize("owner", "init", "host", s.epoch, "654321", async () => true)).rejects.toThrow();
    now = 1100;
    expect(await s.authorized("owner", s.epoch)).toBe(false);
    now = 1000;
    await setupLaunchPin("111111", dir);
    expect(await s.authorized("owner", s.epoch)).toBe(false);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
