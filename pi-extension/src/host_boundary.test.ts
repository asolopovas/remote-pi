import { describe, expect, test } from "vitest";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { rpcSpawnArgs } from "./daemon/rpc_child.js";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const host = join(root, "host");
const cli = process.env.REMOTE_PI_TEST_HOST_CLI || join(root, "build/managed-runtime/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
const manifest = (path: string) => JSON.parse(readFileSync(path, "utf8"));

describe("host/standalone import boundary", () => {
  test("host entry is source-only and peer-only; standalone keeps its runtime dependencies", () => {
    const pkg = manifest(join(host, "package.json"));
    expect(pkg.private).toBe(true);
    expect(pkg.dependencies).toBeUndefined();
    expect(pkg.peerDependencies).toEqual({ "@earendil-works/pi-coding-agent": "*", "@earendil-works/pi-tui": "*", typebox: "*" });
    expect(pkg.pi.extensions).toEqual(["./index.ts"]);
    expect(readFileSync(join(host, "index.ts"), "utf8")).toContain('from "../src/index.js"');
    const standalone = manifest(join(root, "package.json"));
    expect(standalone.dependencies["@earendil-works/pi-coding-agent"]).toBe("^0.79.10");
    expect(standalone.bin["remote-pi"]).toBe("dist/index.js");
  });

  test("real Pi source resolvers and host identities; supervisor excludes legacy registrations", () => {
    const dir = mkdtempSync(join(tmpdir(), "remote-pi-host-boundary-"));
    try {
      const agent = join(dir, "agent");
      mkdirSync(agent);
      mkdirSync(join(dir, ".pi"));
      writeFileSync(join(dir, ".pi/settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture-model" }));
      const trace = join(dir, "modules.jsonl");
      const hook = join(dir, "trace.mjs");
      const chunks = join(resolve(cli), "..", "chunks");
      const virtualFile = readdirSync(chunks).filter(name => /^virtual-modules-.*\.js$/.test(name));
      expect(virtualFile).toHaveLength(1);
      // Observe native ESM/CJS resolution as well as Jiti's virtual-module log.
      writeFileSync(hook, `import { registerHooks } from 'node:module';
import { appendFileSync } from 'node:fs';
registerHooks({ resolve(s,c,next) { const r=next(s,c); appendFileSync(${JSON.stringify(trace)},JSON.stringify({specifier:s,parent:c.parentURL,resolved:r.url})+'\\n'); return r; } });
globalThis[Symbol.for('remote-pi.test.host-exports')] = (await import(${JSON.stringify(pathToFileURL(join(chunks, virtualFile[0])).href)})).VIRTUAL_MODULES;`);
      const proof = join(dir, "proof.json");
      const env: NodeJS.ProcessEnv = { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, HOME: dir, USERPROFILE: dir, REMOTE_PI_HOME: dir, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", NODE_PATH: "", NODE_OPTIONS: "", JITI_DEBUG: "1", REMOTE_PI_HOST_PROOF: proof };
      const run = (args: string[], input?: string) => spawnSync(process.execPath, ["--import", hook, resolve(cli), ...args], { cwd: dir, env, input, encoding: "utf8", timeout: 60_000, maxBuffer: 8 * 1024 * 1024 });
      const install = run(["install", host]);
      expect(install.status, install.stderr).toBe(0);
      const probe = run(["--offline", "-ns", "-np", "--no-themes", "-nc", "--no-session", "--mode", "rpc", "-e", join(root, "tests/fixtures/host-api.ts")], '{"id":"boundary","type":"get_state"}\n');
      expect(probe.status, probe.stderr).toBe(0);
      expect(probe.stdout).toContain('"command":"get_state","success":true');
      expect(manifest(proof)).toMatchObject({ apis: true, identity: true, builtResolvers: true, lifecycleCount: 1, registered: expect.arrayContaining(["agent_send", "list_peers"]) });
      const log = probe.stderr.replace(/\x1b\[[0-9;]*m/g, "");
      for (const name of ["@earendil-works/pi-coding-agent", "@earendil-works/pi-tui", "typebox"]) expect(log).toContain(`[virtual] ${name}`);
      expect(log).toContain(join(root, "src/index.ts"));
      expect(log).toContain(join(root, "src/session/tools.ts"));
      expect(log).not.toMatch(/host-provided|Failed to load extension|Extension errors/i);
      const provenance = readFileSync(trace, "utf8");
      expect(provenance).not.toMatch(/\.pnpm\/(?:@earendil-works\+pi-|typebox@)/);
      expect(provenance).not.toContain(join(root, "dist/index.js"));

      // Reproduce both legacy global package and project dist registrations.
      // The supervisor's real args must exclude their tools and lifecycle hooks.
      const implicit = join(dir, "implicit.ts");
      const marker = join(dir, "implicit-loaded");
      writeFileSync(implicit, `import { writeFileSync } from 'node:fs'; export default pi => { writeFileSync(${JSON.stringify(marker)}, 'factory'); pi.on('session_start', () => writeFileSync(${JSON.stringify(marker)}, 'lifecycle')); };`);
      writeFileSync(join(agent, "settings.json"), JSON.stringify({ packages: [root], extensions: [implicit] }));
      writeFileSync(join(dir, ".pi/settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture-model", extensions: [join(root, "dist/index.js"), implicit] }));
      // Negative control: --help loads factories but starts no session/services.
      // Prove these settings really discover the old closure when not isolated.
      const control = run(["--offline", "--approve", "--help", "-nc"]);
      expect(control.status, control.stderr).toBe(0);
      expect(existsSync(marker)).toBe(true);
      expect(readFileSync(trace, "utf8")).toContain(join(root, "dist/index.js"));
      rmSync(marker);
      rmSync(proof);
      writeFileSync(trace, "");
      const isolated = run([...rpcSpawnArgs(join(host, "index.ts"), "boundary", false), "--offline", "-ns", "-np", "--no-themes", "-nc", "--no-session", "-e", join(root, "tests/fixtures/host-api.ts")], '{"id":"isolated","type":"get_state"}\n');
      expect(isolated.status, isolated.stderr).toBe(0);
      expect(isolated.stdout).toContain('"command":"get_state","success":true');
      expect(existsSync(marker)).toBe(false);
      expect(manifest(proof)).toMatchObject({ identity: true, builtResolvers: true, lifecycleCount: 1 });
      expect(isolated.stderr).not.toMatch(/Failed to load extension|conflict|duplicate/i);
      const isolatedProvenance = readFileSync(trace, "utf8");
      expect(isolatedProvenance).not.toContain(join(root, "dist/index.js"));
      expect(isolatedProvenance).not.toMatch(/\.pnpm\/(?:@earendil-works\+pi-|typebox@)/);

    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, 90_000);

  test("built Node CLI and supervisor resolve locally without global module lookup", () => {
    const dir = mkdtempSync(join(tmpdir(), "remote-pi-standalone-boundary-"));
    try {
      for (const entry of ["index.js", "bin/supervisord.js"]) {
        const result = spawnSync(process.execPath, [join(root, "dist", entry), "--help"], { cwd: dir, env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, HOME: dir, REMOTE_PI_HOME: dir, PI_CODING_AGENT_DIR: dir, NODE_PATH: "", NODE_OPTIONS: "" }, encoding: "utf8", timeout: 30_000 });
        expect(result.status, result.stderr).toBe(0);
        expect(result.stdout).toContain("Usage:");
      }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }, 60_000);
});
