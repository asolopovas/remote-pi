import { test, expect, vi } from "vitest";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { LaunchRegistry } from "./launch_store.js";
import { launchSandbox } from "./launch_sandbox.js";

test("real bubblewrap confines writes, symlink traversal and host HOME while keeping runtime readable", async () => {
  const root = await mkdtemp(join(tmpdir(), "launch-sandbox-"));
  const project = join(root, "project"); const outside = join(root, "outside");
  await mkdir(project); await mkdir(outside); await writeFile(join(outside, "secret"), "unchanged");
  await symlink(outside, join(project, "escape"));
  const credentials = join(root, "credentials"); await mkdir(credentials);
  await writeFile(join(credentials, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: "fixture-openai" }, anthropic: { type: "api_key", key: "fixture-excluded" } }), { mode: 0o600 });
  await writeFile(join(credentials, "settings.json"), JSON.stringify({ defaultProvider: "openai", defaultModel: "gpt-4o-mini", extensions: ["must-not-copy"] }));
  vi.stubEnv("PI_CODING_AGENT_DIR", credentials);
  const store = join(root, "store");
  try {
    const registry = new LaunchRegistry(store);
    const entry = await registry.add("fixture", project, [project]);
    const plan = await launchSandbox(entry, resolve("dist/index.js"), [], "fixture");
    try {
      const cut = plan.args.indexOf("--");
      // No IPC for this shell probe; preserve a pipe in fd3 just like a child.
      const script = `printf allowed > '${project}/ok'; test ! -e '${outside}/secret'; ! printf denied > '${project}/escape/secret'; ! printf denied > /usr/launch-denied; test ! -e '${process.env.HOME}/.pi/remote'; test -r '${resolve("dist/index.js")}'; test -d /home/pi/.pi/agent; grep -q fixture-openai /home/pi/.pi/agent/auth.json; ! grep -q fixture-excluded /home/pi/.pi/agent/auth.json; ! grep -q must-not-copy /home/pi/.pi/agent/settings.json; test $(stat -c %a /home/pi/.pi/agent/auth.json) = 600`;
      const child = spawn(plan.command, [...plan.args.slice(0, cut + 1), "/bin/sh", "-c", script], { env: plan.env, stdio: ["ignore", "pipe", "pipe", "pipe", ...plan.fds] });
      let error = ""; child.stderr.on("data", b => { error += b; });
      const code = await new Promise<number | null>((ok, fail) => { child.on("exit", ok); child.on("error", fail); });
      expect(code, error).toBe(0);
      expect(await readFile(join(project, "ok"), "utf8")).toBe("allowed");
      expect(await readFile(join(outside, "secret"), "utf8")).toBe("unchanged");
    } finally { await plan.close(); }
  } finally { vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true }); }
}, 15000);
