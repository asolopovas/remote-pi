import { expect, test } from "vitest";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

test("temporary real Pi 0.79.10 RPC SDK requires next command for requested orderly shutdown; no inference", async () => {
  const home = await mkdtemp(join(tmpdir(), "session-control-smoke-"));
  const agent = join(home, "agent"); await mkdir(agent);
  const trace = join(home, "trace.jsonl");
  const extension = join(home, "stop-fixture.ts");
  const helper = new URL(`file://${resolve("dist/session/session_control.js")}`).href;
  await writeFile(join(agent, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: "synthetic-not-a-real-key" } }), { mode: 0o600 });
  await writeFile(extension, `
import { appendFileSync } from 'node:fs';
import { SessionControl } from ${JSON.stringify(helper)};
const trace = value => appendFileSync(${JSON.stringify(trace)}, JSON.stringify(value) + '\\n');
export default function(pi) {
  pi.on('agent_start', () => trace('UNEXPECTED_PROVIDER_INFERENCE'));
  pi.on('session_shutdown', () => trace('session_shutdown'));
  pi.registerCommand('fixture-stop', { handler: async (_args, ctx) => {
    const id = ctx.sessionManager.getSessionId();
    const control = new SessionControl();
    const target = { current: () => ctx.sessionManager.getSessionId() === id,
      authorized: async () => true, eligible: () => true, reason: 'Synthetic isolated smoke', completion: 'requested',
      stop: () => { trace('abort'); ctx.abort(); trace('shutdown'); ctx.shutdown(); } };
    let token;
    await control.handle('synthetic-owner', { type: 'session_control_status', id: 'status', room_id: 'synthetic-room' }, target, r => { token = r.token; trace(r.type); });
    await control.handle('synthetic-owner', { type: 'session_stop', id: 'stop', room_id: 'synthetic-room', token }, target, r => trace(r.state));
  } });
}
`);
  const cli = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent").replace(/\/dist\/index\.js$/, "/dist/cli.js"));
  const child = spawn(process.execPath, [cli, "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--provider", "openai", "--model", "gpt-4o-mini", "-e", extension], {
    cwd: home, env: { PATH: process.env.PATH, HOME: home, USERPROFILE: home, REMOTE_PI_HOME: join(home, "remote"), PI_CODING_AGENT_DIR: agent, TERM: "dumb" }, stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", chunk => { output += chunk.toString(); }); child.stderr.on("data", chunk => { output += chunk.toString(); });
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const exited = new Promise<number | null>((ok, fail) => { child.once("exit", ok); child.once("error", fail); });
    child.stdin.write(JSON.stringify({ type: "prompt", id: "smoke", message: "/fixture-stop" }) + "\n");
    // RPC 0.79.10 does not act on an external SDK shutdown request until
    // another command arrives. Production therefore advertises only TUI support.
    await expect.poll(async () => { try { return await readFile(trace, "utf8"); } catch { return ""; } }, { timeout: 10_000 }).toContain('"shutdown"');
    child.stdin.write(JSON.stringify({ type: "get_state", id: "flush-sdk-shutdown" }) + "\n");
    const code = await Promise.race([exited, new Promise<never>((_, reject) => { timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`Temporary Pi smoke timed out: ${output}`)); }, 15_000); })]);
    expect(code, output).toBe(0);
    expect((await readFile(trace, "utf8")).trim().split("\n").map(line => JSON.parse(line))).toEqual(["session_control_status_result", "requested", "abort", "shutdown", "session_shutdown"]);
  } finally { clearTimeout(timer); if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); await rm(home, { recursive: true, force: true }); }
}, 20_000);
