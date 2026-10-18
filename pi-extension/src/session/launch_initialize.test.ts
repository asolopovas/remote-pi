import { test, expect } from "vitest";
import { mkdtemp, rm, writeFile, symlink, chmod, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { LaunchSecurity, setupLaunchPin } from "./launch_security.js";
import { createPrivatePin } from "./launch_store.js";
import { SecureLauncher } from "./secure_launcher.js";
import { LaunchRegistry } from "./launch_store.js";
const deferred = () => { let resolve!: () => void; const promise = new Promise<void>(r => { resolve = r; }); return { promise, resolve }; };
const initialize = (s: LaunchSecurity, id = "init", paired = async () => true) => s.initialize("owner", id, s.launcherId, s.epoch, "654321", paired);

test("phone creates same private verifier, Owner-only unlocked rotated status; no overwrite or replay across unlock/setup IDs", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-"));
  try {
    const s = new LaunchSecurity("host", dir);
    expect(await s.status("owner")).toMatchObject({ pin_setup: "available", configured: false });
    const epoch = s.epoch; await initialize(s);
    expect(await s.status("owner")).toMatchObject({ pin_setup: "configured", configured: true, unlocked: true });
    expect(s.epoch).not.toBe(epoch);
    expect((await stat(join(dir, "pin.json"))).mode & 0o777).toBe(0o600);
    const before = await readFile(join(dir, "pin.json"), "utf8");
    expect(before).not.toContain("654321");
    await expect(initialize(s, "overwrite")).rejects.toThrow();
    await expect(s.unlock("owner", "init", "host", s.epoch, "654321", async () => true)).rejects.toThrow();
    expect(await readFile(join(dir, "pin.json"), "utf8")).toBe(before);
    await s.unlock("owner", "unlock", "host", s.epoch, "654321", async () => true);
    expect((await s.status("owner")).unlocked).toBe(true);
    await expect(initialize(s, "unlock")).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test.each(["corrupt", "symlink", "unsafe-file", "unsafe-directory"])("%s cannot advertise availability or be replaced", async kind => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-unsafe-"));
  try {
    const path = join(dir, "pin.json");
    if (kind === "symlink") await symlink(join(dir, "missing"), path);
    else if (kind !== "unsafe-directory") await writeFile(path, "corrupt", { mode: kind === "unsafe-file" ? 0o644 : 0o600 });
    else await chmod(dir, 0o755);
    const s = new LaunchSecurity("host", dir);
    expect((await s.status("owner")).pin_setup).toBe("unavailable");
    await expect(initialize(s)).rejects.toThrow();
    if (kind === "corrupt" || kind === "unsafe-file") expect(await readFile(path, "utf8")).toBe("corrupt");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test.each(["Lock", "pairing", "lifecycle", "channel"])("%s during derivation prevents creation; shared single-flight", async change => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-revoke-"));
  const entered = deferred(), release = deferred(); let current = true;
  const s = new LaunchSecurity("host", dir, Date.now, 300000, async () => { entered.resolve(); await release.promise; return Buffer.alloc(32); });
  try {
    const pending = initialize(s, "init", async () => current);
    await entered.promise;
    await expect(s.unlock("owner", "parallel", "host", s.epoch, "654321", async () => true)).rejects.toThrow();
    if (change === "Lock") s.lock(); else current = false;
    release.resolve(); await expect(pending).rejects.toThrow("Authority changed");
    expect((await s.status("owner")).pin_setup).toBe("available");
    await expect(initialize(s, "init")).rejects.toThrow();
  } finally { release.resolve(); await rm(dir, { recursive: true, force: true }); }
});

test("final staging authority check and exclusive publication fail closed", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-final-"));
  try {
    await expect(createPrivatePin(dir, {}, async () => {}, () => { throw new Error("revoked"); })).rejects.toThrow("revoked");
    expect((await new LaunchSecurity("host", dir).status("owner")).pin_setup).toBe("available");
    await expect(createPrivatePin(dir, {}, async () => { await writeFile(join(dir, "pin.json"), "existing", { mode: 0o600 }); }, () => {})).rejects.toThrow();
    expect(await readFile(join(dir, "pin.json"), "utf8")).toBe("existing");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("remote initializers serialize; local replacement remains local-only; request budget never evicts", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-race-"));
  try {
    const a = new LaunchSecurity("a", dir), b = new LaunchSecurity("b", dir);
    const results = await Promise.allSettled([initialize(a), initialize(b)]);
    expect(results.filter(r => r.status === "fulfilled")).toHaveLength(1);
    const record = await readFile(join(dir, "pin.json"), "utf8");
    await expect(initialize(new LaunchSecurity("c", dir))).rejects.toThrow();
    expect(await readFile(join(dir, "pin.json"), "utf8")).toBe(record);
    await setupLaunchPin("111111", dir);
    const s = new LaunchSecurity("budget", dir);
    for (let i = 0; i < 256; i++) await expect(initialize(s, String(i))).rejects.toThrow();
    await expect(s.unlock("owner", "257", "budget", s.epoch, "111111", async () => true)).rejects.toThrow();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("secure launcher initialize returns correlated unlocked status and rejects revoked owner", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pin-init-handler-"));
  const launcher = new SecureLauncher({ cwd: dir, extensionPath: "unused", registry: new LaunchRegistry(dir), keypair: async () => { throw new Error("unused"); }, paired: async () => true, current: () => true });
  try {
    const request = { type: "launcher_pin_initialize", id: "phone", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, pin: "654321" } as const;
    expect(await launcher.handle("owner", request, async () => false)).toMatchObject({ type: "error", in_reply_to: "phone" });
    expect(await launcher.handle("owner", { ...request, epoch: launcher.security.epoch }, async () => true)).toMatchObject({ type: "launcher_status_result", in_reply_to: "phone", status: { configured: true, pin_setup: "configured", unlocked: true } });
  } finally { await launcher.shutdown(); await rm(dir, { recursive: true, force: true }); }
});

test("separate processes initialize create-only under shared local transaction lock", async () => {
  const { spawn } = await import("node:child_process");
  const { resolve } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "pin-init-process-"));
  try {
    const code = `import {LaunchSecurity} from ${JSON.stringify("file://" + resolve("dist/session/launch_security.js"))}; let input=''; for await(const b of process.stdin) input+=b; const dir=JSON.parse(input); const s=new LaunchSecurity('host',dir); try { await s.initialize('owner','init','host',s.epoch,'654321',async()=>true); } catch { process.exitCode=2; }`;
    const run = () => new Promise<number | null>((ok, fail) => {
      const child = spawn(process.execPath, ["--input-type=module", "-e", code], { stdio: ["pipe", "ignore", "ignore"] });
      child.once("exit", ok); child.once("error", fail); child.stdin.end(JSON.stringify(dir));
    });
    expect((await Promise.all([run(), run()])).sort()).toEqual([0, 2]);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("local setup committed while remote waits for lock cannot be overwritten", async () => {
  const { withLaunchStoreLock, writePrivateJson, readPrivateJson } = await import("./launch_store.js");
  const dir = await mkdtemp(join(tmpdir(), "pin-init-local-race-"));
  const entered = deferred(), release = deferred();
  try {
    // Capture the exact local setup record, then serialize its publication like the CLI.
    await setupLaunchPin("111111", dir);
    const record = await readPrivateJson(dir, "pin.json");
    await rm(join(dir, "pin.json"));
    const local = withLaunchStoreLock(dir, async () => { entered.resolve(); await release.promise; await writePrivateJson(dir, "pin.json", record); });
    await entered.promise;
    const remote = initialize(new LaunchSecurity("host", dir));
    release.resolve(); await local;
    await expect(remote).rejects.toThrow("unavailable");
    expect(await readPrivateJson(dir, "pin.json")).toEqual(record);
  } finally { release.resolve(); await rm(dir, { recursive: true, force: true }); }
});
