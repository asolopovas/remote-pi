import { test, expect, vi } from "vitest";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { LaunchRegistry } from "./launch_store.js";
import { rpcSpawnArgs } from "../daemon/rpc_child.js";
import { launchSandbox } from "./launch_sandbox.js";

test.each(["modern", "bridge", "old"])("real modern bundled CLI selects recognized Sol metadata without a model turn (runtime=%s)", async runtime => {
  const root = await mkdtemp(join(tmpdir(), "modern-model-"));
  const project = join(root, "project"), agent = join(root, "agent");
  await mkdir(project); await mkdir(agent);
  await writeFile(join(agent, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: "synthetic", refresh: "synthetic", expires: Date.now() + 86400000 } }), { mode: 0o600 });
  await writeFile(join(agent, "settings.json"), JSON.stringify({ defaultProvider: "openai-codex", defaultModel: "gpt-6.1-sol" }));
  vi.stubEnv("PI_CODING_AGENT_DIR", agent);
  const entry = await new LaunchRegistry(join(root, "store")).add("fixture", project, [project]);
  const plan = await launchSandbox(entry, resolve("dist/index.js"), runtime === "bridge" ? rpcSpawnArgs(resolve("dist/index.js"), "fixture", false).filter(a => a !== "--approve") : ["--mode", "rpc"], "fixture");
  let child: ReturnType<typeof spawn> | undefined;
  try {
    // Child cannot contact any provider, production relay, or OAuth endpoint.
    let args = plan.args;
    if (runtime === "old") {
      const oldRoot = resolve(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "..");
      const cut = args.indexOf("--");
      // Reproduce the original settings-only selection on cached 0.79.10.
      args = [...args.slice(0, cut + 1), process.execPath, join(oldRoot, "dist/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve", "--no-session"];
    }
    child = spawn(plan.command, ["--unshare-net", ...args], { env: plan.env, stdio: ["pipe", "pipe", "pipe", "pipe", ...plan.fds] });
    let output = "", error = "";
    child.stdout!.on("data", b => { if (output.length < 65536) output += b; });
    child.stderr!.on("data", b => { if (error.length < 65536) error += b; });
    child.stdin!.on("error", () => {});
    child.stdin!.write('{"type":"get_state","id":"probe"}\n');
    await expect.poll(() => {
      if (/Cannot find (?:package|module)/.test(error)) throw new Error("Selected runtime closure is missing a dependency");
      if (/SyntaxError|TypeError|ReferenceError|ERR_/.test(error)) throw new Error("Runtime startup failed; inspect the synthetic fixture locally");
      return output.split("\n").some(line => { try { return JSON.parse(line).id === "probe"; } catch { return false; } });
    }, { timeout: 10000 }).toBe(true);
    const state = output.split("\n").map(line => { try { return JSON.parse(line); } catch { return {}; } }).find(s => s.id === "probe");
    if (runtime === "old") {
      expect(state).toMatchObject({ success: true, data: { model: { provider: "openai-codex", id: "gpt-5.5" } } });
      expect(state.data.model.id).not.toBe("gpt-6.1-sol");
      return;
    }
    expect(state).toMatchObject({ success: true, data: { model: { provider: "openai-codex", id: "gpt-6.1-sol", api: "openai-codex-responses", contextWindow: 500000, maxTokens: 128000, compat: { supportsOpenAIGrammarTools: true, supportsAdditionalTools: true, supportsToolSearch: true, supportsMidConvoSystemMessages: true } } } });
  } finally {
    if (child && child.exitCode === null) { const ended = new Promise(r => child!.once("exit", r)); child.kill("SIGKILL"); await ended; }
    await plan.close(); vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true });
  }
}, 15000);
