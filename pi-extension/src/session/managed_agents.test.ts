import { afterEach, describe, expect, test, vi } from "vitest";
import { ChildProcess, spawn } from "node:child_process";
import { PassThrough } from "node:stream";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ManagedAgents, managedChildEnv, type ManagedSpawn, type ManagedOptions } from "./managed_agents.js";
import { roomIdFor } from "../rooms.js";
import type { AgentRequest, ServerMessage } from "../protocol/types.js";

const dirs: string[] = [];
const managers: ManagedAgents[] = [];
afterEach(async () => {
  await Promise.all(managers.splice(0).map(m => m.shutdown()));
  dirs.splice(0).forEach(d => rmSync(d, { recursive: true, force: true }));
});
const allowed = async () => true;
function harness(mode: "ready" | "timeout" | "enoent" | "crash" | "bad-room" | "rpc-only" | "ipc-only" | "output" = "ready", killOn = "SIGTERM", overrides: Partial<ManagedOptions> = {}, model?: unknown, readyFirst = false) {
  const cwd = mkdtempSync(join(tmpdir(), "managed-agent-")); dirs.push(cwd);
  const children: ChildProcess[] = [];
  const spawnMock = vi.fn<ManagedSpawn>().mockImplementation((_command, args, options) => {
    const child = new ChildProcess();
    Object.assign(child, { pid: mode === "enoent" ? undefined : 123, stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough() });
    child.kill = vi.fn().mockImplementation((signal: string) => {
      if (signal === killOn) queueMicrotask(() => child.emit("exit", null, signal));
      return true;
    });
    const cfg = JSON.parse(options?.env?.REMOTE_PI_DIRECT_CONFIG ?? "{}") as { agent_name: string };
    children.push(child);
    child.stdin?.on("data", (data: Buffer) => {
      if (["timeout", "ipc-only"].includes(mode)) return;
      const rpc = JSON.parse(data.toString()) as { id: string };
      child.stdout?.emit("data", Buffer.from(JSON.stringify({ type: "response", command: "get_state", id: rpc.id, success: true, data: { model } }) + "\n"));
    });
    queueMicrotask(() => {
      if (mode === "enoent") { child.emit("error", Object.assign(new Error("secret-path"), { code: "ENOENT" })); return; }
      if (!readyFirst) child.emit("spawn");
      if (mode === "crash") { child.emit("exit", 1, null); return; }
      if (mode === "output") child.stdout?.emit("data", Buffer.alloc(70_000, "x"));
      if (!["timeout", "rpc-only"].includes(mode)) child.emit("message", { type: "remote_pi_managed_ready", ok: true, name: cfg.agent_name,
        room_id: mode === "bad-room" ? "wrong-room" : roomIdFor(cwd, cfg.agent_name) });
      if (readyFirst) child.emit("spawn");
    });
    expect(args).not.toContain("--continue");
    expect(args).not.toContain("--resume");
    expect(args).toContain("--approve");
    return child;
  });
  const manager = new ManagedAgents({ cwd, extensionPath: "/extension.js", spawn: spawnMock, readinessMs: 25, stopMs: 10, ...overrides }); managers.push(manager);
  type Input = Exclude<AgentRequest, { type: "agent_launch" }> | (Omit<Extract<AgentRequest, { type: "agent_launch" }>, "launcher_id"> & { launcher_id?: string });
  const request = (r: Input, owner = "owner-a", auth = allowed) => manager.handle(owner,
    r.type === "agent_launch" ? { ...r, launcher_id: r.launcher_id ?? manager.launcherId } : r, auth);
  const launch = (id = "launch", name?: string) => request({ type: "agent_launch", id, cwd, ...(name ? { name } : {}) });
  return { cwd, manager, children, spawnMock, request, launch };
}
function agent(result: ServerMessage) {
  if (result.type !== "agent_launch_result" && result.type !== "agent_stop_result") throw new Error(JSON.stringify(result));
  return result.agent;
}

describe("ManagedAgents lifecycle", () => {
  test("prepared sandbox spawn failure never misidentifies bubblewrap as missing Pi", async () => {
    const h = harness("enoent", "SIGTERM", { prepareSpawn: async agent => ({ command: "/bin/bwrap", args: ["--approve"], options: { env: { REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: agent.name }) } }, close: async () => {} }) });
    expect(await h.launch()).toMatchObject({ type: "error", message: "Secure sandbox process could not start; inspect local bubblewrap runtime and project permissions" });
  });
  test("unexpected preparation failure is truthful and never leaks exception details or claims missing Pi", async () => {
    const h = harness("ready", "SIGTERM", { prepareSpawn: async () => { throw new Error("sensitive-unexpected-detail"); } });
    const result = await h.launch();
    expect(result).toMatchObject({ type: "error", code: "internal_error", message: "Pi startup failed unexpectedly; inspect the host launcher locally and refresh status before retrying" });
    expect(JSON.stringify(result)).not.toMatch(/sensitive|PATH/);
    expect(h.spawnMock).not.toHaveBeenCalled();
  });
  test("prepared spawn rechecks lock authority synchronously and never starts a revoked child", async () => {
    let release!: () => void; let entered!: () => void; let granted = true;
    const waiting = new Promise<void>(r => { release = r; }); const preparing = new Promise<void>(r => { entered = r; });
    const close = vi.fn(async () => {});
    const h = harness("ready", "SIGTERM", { admitted: () => granted,
      prepareSpawn: async () => { entered(); await waiting; return { command: "pi", args: [], options: {}, close }; },
    });
    const pending = h.launch(); await preparing; granted = false; release();
    expect(await pending).toMatchObject({ type: "error", code: "invalid_message" });
    expect(h.spawnMock).not.toHaveBeenCalled(); expect(close).toHaveBeenCalledTimes(1);
  });
  test("owner-only shutdown reports incomplete cleanup, excludes foreign children, and retries safely", async () => {
    const h = harness("ready", "NEVER");
    await h.launch("owned"); await h.request({ type: "agent_launch", id: "foreign", cwd: h.cwd }, "owner-b");
    expect(await h.manager.shutdownOwner("owner-a")).toBe(false);
    expect(h.children[0].kill).toHaveBeenCalledWith("SIGKILL"); expect(h.children[1].kill).not.toHaveBeenCalled();
    h.children[0].emit("exit", null, "SIGKILL");
    expect(await h.manager.shutdownOwner("owner-a")).toBe(true);
    h.children[1].emit("exit", null, "SIGKILL");
  });
  test("replacement launcher rejects replay from an old incarnation without spawning", async () => {
    const old = harness(), replacement = harness();
    const request = { type: "agent_launch", id: "lost-reply", launcher_id: old.manager.launcherId, cwd: old.cwd } as const;
    expect(await old.request(request)).toMatchObject({ type: "agent_launch_result" });
    await old.manager.shutdown();
    expect(await replacement.request(request)).toMatchObject({ type: "error", code: "invalid_message", message: expect.stringContaining("session changed") });
    expect(replacement.spawnMock).not.toHaveBeenCalled();
    expect(await replacement.request({ type: "agent_list", id: "new-capability" })).toMatchObject({ launcher_id: replacement.manager.launcherId });
  });
  test("replaying original ID settles delayed admission without a duplicate after an empty snapshot", async () => {
    const h = harness();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let checks = 0;
    const auth = async () => { if (++checks === 2) await gate; return true; };
    const request = { type: "agent_launch", id: "delayed", cwd: h.cwd } as const;
    const original = h.request(request, "owner-a", auth);
    await vi.waitFor(() => expect(checks).toBe(2));
    expect(await h.request({ type: "agent_list", id: "not-proof-of-completion" })).toMatchObject({ agents: [] });
    let settled = false;
    const replay = h.request(request).then(result => { settled = true; return result; });
    await Promise.resolve();
    expect(settled).toBe(false);
    expect(h.spawnMock).not.toHaveBeenCalled();
    release();
    expect(await replay).toEqual(await original);
    expect(h.spawnMock).toHaveBeenCalledTimes(1);
  });
  test("fresh, unique same-cwd identities; parallel dedupe and conflicting payload IDs", async () => {
    const h = harness();
    const [a, replay] = await Promise.all([h.launch("one", "review"), h.launch("one", "review")]);
    expect(replay).toEqual(a); expect(h.spawnMock).toHaveBeenCalledTimes(1);
    const b = agent(await h.launch("two", "review"));
    expect(b.name).not.toBe(agent(a).name); expect(b.room_id).not.toBe(agent(a).room_id);
    expect(agent(a).state).toBe("running");
    expect(await h.launch("one", "other")).toMatchObject({ type: "error", code: "invalid_message" });
    expect(await h.request({ type: "agent_stop", id: "one", agent_id: b.agent_id })).toMatchObject({ type: "error", code: "invalid_message" });
  });
  test("owner-scoped keys, list and stop; no arbitrary PID/pre-existing agent control", async () => {
    const h = harness(); const a = agent(await h.launch());
    expect(await h.request({ type: "agent_list", id: "list" }, "owner-b")).toMatchObject({ agents: [] });
    expect(await h.request({ type: "agent_stop", id: "stop", agent_id: a.agent_id }, "owner-b")).toMatchObject({ type: "error", code: "invalid_message" });
    expect(await h.request({ type: "agent_stop", id: "pid", agent_id: "123" })).toMatchObject({ type: "error" });
    expect(agent(await h.request({ type: "agent_launch", id: "launch", cwd: h.cwd }, "owner-b")).agent_id).not.toBe(a.agent_id);
    expect(h.children[0].kill).not.toHaveBeenCalled();
  });
  test("parallel admission globally bounded to four live children", async () => {
    const h = harness(); const results = await Promise.all(Array.from({ length: 8 }, (_, i) => h.launch(String(i))));
    expect(results.filter(r => r.type === "agent_launch_result")).toHaveLength(4);
    expect(results.filter(r => r.type === "error")).toHaveLength(4); expect(h.children).toHaveLength(4);
    const a = agent(results.find(r => r.type === "agent_launch_result")!);
    await h.request({ type: "agent_stop", id: "stop", agent_id: a.agent_id });
    expect(await h.launch("another")).toMatchObject({ type: "agent_launch_result" });
  });
  test("stop/replayed stop is idempotent, escalates and releases capacity; shutdown owns only its children", async () => {
    const h = harness("ready", "SIGKILL"); const a = agent(await h.launch());
    const stop = { type: "agent_stop", id: "stop", agent_id: a.agent_id } as const;
    const [s1, s2] = await Promise.all([h.request(stop), h.request(stop)]);
    expect(s2).toEqual(s1); expect(agent(s1).state).toBe("stopped");
    expect(h.children[0].kill).toHaveBeenCalledWith("SIGTERM"); expect(h.children[0].kill).toHaveBeenCalledWith("SIGKILL");
    expect(agent(await h.request({ ...stop, id: "stop-again" })).state).toBe("stopped");
    await h.launch("live"); await h.manager.shutdown();
    expect(h.children[1].kill).toHaveBeenCalledWith("SIGKILL");
    expect(await h.launch("after-shutdown")).toMatchObject({ type: "error" });
  });
  test.each(["timeout", "enoent", "crash", "bad-room", "rpc-only", "ipc-only", "output"] as const)("%s is not declared running and partial child is cleaned", async mode => {
    const h = harness(mode); const result = await h.launch();
    expect(result).toMatchObject({ type: "error", code: ["timeout", "rpc-only", "ipc-only"].includes(mode) ? "timeout" : "internal_error" });
    expect(JSON.stringify(result)).not.toContain("secret-path");
    expect(await h.request({ type: "agent_list", id: "list" })).toMatchObject({ agents: [{ state: "failed" }] });
    expect(await h.launch()).toEqual(result); expect(h.children).toHaveLength(1);
    if (!["enoent", "crash"].includes(mode)) expect(h.children[0].kill).toHaveBeenCalled();
  });
  test.each(["SIGTERM", "never"])("stopping a failed child (%s) removes the error without changing earlier snapshots or replay", async killOn => {
    const h = harness("timeout", killOn);
    const failedLaunch = await h.launch();
    const before = await h.request({ type: "agent_list", id: "before-stop" });
    if (before.type !== "agent_list_result") throw new Error("missing list");
    const failed = before.agents[0];
    expect(failed.state).toBe("failed");
    expect(Object.hasOwn(failed, "error")).toBe(true);
    if (killOn === "never") {
      h.children[0].kill = vi.fn().mockImplementation((signal: string) => {
        queueMicrotask(() => h.children[0].emit("exit", null, signal));
        return true;
      });
    }
    const stop = { type: "agent_stop", id: "stop-failed", agent_id: failed.agent_id } as const;
    const stopped = await h.request(stop);
    expect(agent(stopped).state).toBe("stopped");
    expect(Object.hasOwn(agent(stopped), "error")).toBe(false);
    expect(JSON.parse(JSON.stringify(agent(stopped)))).not.toHaveProperty("error");
    const after = await h.request({ type: "agent_list", id: "after-stop" });
    if (after.type !== "agent_list_result") throw new Error("missing list");
    expect(after.agents).toEqual([agent(stopped)]);
    expect(Object.hasOwn(after.agents[0], "error")).toBe(false);
    expect(failed.state).toBe("failed");
    expect(Object.hasOwn(failed, "error")).toBe(true);
    expect(await h.launch()).toEqual(failedLaunch);
    expect(await h.request(stop)).toEqual(stopped);
    const terminal = agent(await h.request({ ...stop, id: "terminal-stop" }));
    expect(terminal).toEqual(agent(stopped));
    expect(Object.hasOwn(terminal, "error")).toBe(false);
  });
  test("explicit Stop during startup leaves the current record stopped without a stale failure", async () => {
    const h = harness("timeout");
    const launch = h.launch();
    await vi.waitFor(() => expect(h.children).toHaveLength(1), { interval: 1 });
    const list = await h.request({ type: "agent_list", id: "starting" });
    if (list.type !== "agent_list_result") throw new Error("missing list");
    expect(list.agents[0].state).toBe("starting");
    const stopped = await h.request({ type: "agent_stop", id: "stop-starting", agent_id: list.agents[0].agent_id });
    expect(agent(stopped).state).toBe("stopped");
    expect(await launch).toMatchObject({ type: "error" });
    const after = await h.request({ type: "agent_list", id: "after-stop" });
    if (after.type !== "agent_list_result") throw new Error("missing list");
    expect(after.agents).toEqual([agent(stopped)]);
    expect(Object.hasOwn(after.agents[0], "error")).toBe(false);
  });
  test.each(["exit", "timeout"] as const)("explicit Stop joining startup cleanup (%s) finalizes only after successful exit", async outcome => {
    vi.useFakeTimers();
    const h = harness("timeout", "never");
    let signalSpawned!: () => void;
    const spawned = new Promise<void>(resolve => { signalSpawned = resolve; });
    let signalCleanup!: () => void;
    const cleanupStarted = new Promise<void>(resolve => { signalCleanup = resolve; });
    const spawnChild = h.spawnMock.getMockImplementation()!;
    h.spawnMock.mockImplementation((command, args, options) => {
      const child = spawnChild(command, args, options);
      child.kill = vi.fn().mockImplementation((signal: string) => {
        if (signal === "SIGTERM") signalCleanup();
        return true;
      });
      signalSpawned();
      return child;
    });
    try {
      const launch = h.launch();
      await spawned;
      await vi.advanceTimersByTimeAsync(25);
      await cleanupStarted;
      const before = await h.request({ type: "agent_list", id: "cleanup-pending" });
      if (before.type !== "agent_list_result") throw new Error("missing list");
      const failed = before.agents[0];
      expect(failed.state).toBe("failed");
      expect(Object.hasOwn(failed, "error")).toBe(true);
      const request = { type: "agent_stop", id: "join-cleanup", agent_id: failed.agent_id } as const;
      const stop = h.request(request);
      await vi.advanceTimersByTimeAsync(0);
      expect(h.children[0].kill).toHaveBeenCalledTimes(1);
      expect(await h.request({ type: "agent_list", id: "stop-pending" })).toMatchObject({ agents: [{ state: "failed" }] });
      if (outcome === "exit") {
        h.children[0].emit("exit", null, "SIGTERM");
      } else {
        await vi.advanceTimersByTimeAsync(20);
        const rejected = await stop;
        expect(rejected).toMatchObject({ type: "error", code: "timeout" });
        expect(await h.request(request)).toEqual(rejected);
        const live = await h.request({ type: "agent_list", id: "cleanup-rejected" });
        if (live.type !== "agent_list_result") throw new Error("missing list");
        expect(live.agents[0].state).toBe("failed");
        expect(Object.hasOwn(live.agents[0], "error")).toBe(true);
        expect(h.children[0].kill).toHaveBeenCalledTimes(2);
      }
      const failedLaunch = await launch;
      expect(failedLaunch).toMatchObject({ type: "error", code: "timeout" });
      if (outcome === "timeout") {
        const retry = h.request({ ...request, id: "retry-cleanup" });
        await vi.advanceTimersByTimeAsync(0);
        expect(h.children[0].kill).toHaveBeenCalledTimes(3);
        h.children[0].emit("exit", null, "SIGTERM");
        expect(agent(await retry).state).toBe("stopped");
      } else {
        const stopped = agent(await stop);
        expect(stopped.state).toBe("stopped");
        expect(Object.hasOwn(stopped, "error")).toBe(false);
        expect(await h.request(request)).toEqual({ type: "agent_stop_result", in_reply_to: request.id, agent: stopped });
        expect(h.children[0].kill).toHaveBeenCalledTimes(1);
      }
      const after = await h.request({ type: "agent_list", id: "cleanup-complete" });
      if (after.type !== "agent_list_result") throw new Error("missing list");
      expect(after.agents[0].state).toBe("stopped");
      expect(Object.hasOwn(after.agents[0], "error")).toBe(false);
      expect(await h.launch()).toEqual(failedLaunch);
      expect(h.spawnMock).toHaveBeenCalledTimes(1);
    } finally {
      h.children[0]?.emit("exit", null, "SIGTERM");
      vi.useRealTimers();
    }
  });
  test("unsupported runtime request returns a structured error without spawning", async () => {
    const h = harness();
    await expect(h.manager.handle("owner-a", { type: "unsupported", id: "unknown" } as unknown as AgentRequest, allowed))
      .resolves.toMatchObject({ type: "error", in_reply_to: "unknown", code: "invalid_message" });
    expect(h.spawnMock).not.toHaveBeenCalled();
  });
  test("post-readiness crash is retained as failed and never restarted", async () => {
    const h = harness(); await h.launch(); h.children[0].emit("exit", 2, null);
    expect(await h.request({ type: "agent_list", id: "list" })).toMatchObject({ agents: [{ state: "failed", error: expect.stringContaining("code 2") }] });
    expect(h.spawnMock).toHaveBeenCalledTimes(1);
  });
  test("canonical directory, invalid file/path and reserved labels", async () => {
    const h = harness(); const link = join(h.cwd, "link"); symlinkSync(h.cwd, link);
    expect(agent(await h.request({ type: "agent_launch", id: "link", cwd: link })).cwd).toBe(h.cwd);
    const file = join(h.cwd, "file"); writeFileSync(file, "text");
    for (const cwd of [file, join(h.cwd, "missing")]) expect(await h.request({ type: "agent_launch", id: cwd, cwd })).toMatchObject({ code: "invalid_message" });
    expect(await h.launch("reserved", "broker")).toMatchObject({ code: "invalid_message" });
    expect(h.children).toHaveLength(1);
  });
  test("rechecks revocation before admission and after readiness; cleanup on shutdown during startup", async () => {
    const h = harness(); let n = 0;
    expect(await h.request({ type: "agent_launch", id: "revoked", cwd: h.cwd }, "owner-a", async () => ++n < 4)).toMatchObject({ type: "error" });
    expect(h.children[0].kill).toHaveBeenCalled();
    const slow = harness("timeout"); const pending = slow.launch();
    await vi.waitFor(() => expect(slow.children).toHaveLength(1)); await slow.manager.shutdown();
    expect(await pending).toMatchObject({ type: "error" });
    expect(slow.children[0].kill).toHaveBeenCalled();
  });
  test("bounded records and idempotency history refuse new requests without evicting old keys", async () => {
    const h = harness("enoent"); const first = await h.launch("first");
    for (let i = 0; i < 31; i++) await h.launch(`l${i}`);
    expect(await h.launch("full")).toMatchObject({ code: "rate_limited" });
    expect(h.children).toHaveLength(32);
    for (let i = 0; i < 223; i++) await h.request({ type: "agent_launch", id: `full${i}`, cwd: h.cwd });
    for (let i = 0; i < 300; i++) expect(await h.request({ type: "agent_list", id: `list${i}` })).toMatchObject({ type: "agent_list_result" });
    expect(await h.launch("over")).toMatchObject({ code: "rate_limited" });
    expect(await h.launch("first")).toEqual(first); expect(h.children).toHaveLength(32);
  });
  test("saturated history still permits owned stop and fresh/terminal snapshots without spending unauthorized reserves", async () => {
    const h = harness(); const a = agent(await h.launch());
    for (let i = 0; i < 255; i++) await h.request({ type: "agent_launch", id: `invalid${i}`, cwd: join(h.cwd, "missing") });
    expect(await h.launch("over")).toMatchObject({ code: "rate_limited" });
    expect(await h.request({ type: "agent_stop", id: "bad-stop", agent_id: a.agent_id }, "owner-b")).toMatchObject({ code: "invalid_message" });
    const stop = { type: "agent_stop", id: "reserved-stop", agent_id: a.agent_id } as const;
    const stopped = await h.request(stop); expect(agent(stopped).state).toBe("stopped");
    expect(await h.request(stop)).toEqual(stopped);
    expect(await h.request({ ...stop, agent_id: "conflicting" })).toMatchObject({ code: "invalid_message" });
    const terminal = { ...stop, id: "terminal" };
    const [s1, s2] = await Promise.all([h.request(terminal), h.request(terminal)]);
    expect(s1).toEqual(s2); expect(agent(s1).state).toBe("stopped");
    for (let i = 0; i < 300; i++) expect(agent(await h.request({ ...stop, id: `terminal${i}` })).state).toBe("stopped");
    expect(await h.request({ type: "agent_list", id: "fresh" })).toMatchObject({ agents: [{ state: "stopped" }] });
    expect(await h.launch()).toMatchObject({ type: "agent_launch_result" }); expect(h.children).toHaveLength(1);
  });
  test("failed-but-live children use bounded retry reserve and are not reported stopped", async () => {
    const h = harness("timeout", "never"); await h.launch();
    const list = await h.request({ type: "agent_list", id: "list" });
    if (list.type !== "agent_list_result") throw new Error("missing list");
    const a = list.agents[0]; expect(a.state).toBe("failed");
    for (let i = 0; i < 255; i++) await h.request({ type: "agent_launch", id: `invalid${i}`, cwd: join(h.cwd, "missing") });
    for (let i = 0; i < 3; i++) expect(await h.request({ type: "agent_stop", id: `retry${i}`, agent_id: a.agent_id })).toMatchObject({ code: "timeout" });
    expect(await h.request({ type: "agent_stop", id: "retry-over", agent_id: a.agent_id })).toMatchObject({ code: "rate_limited" });
    expect(await h.request({ type: "agent_stop", id: "retry0", agent_id: a.agent_id })).toMatchObject({ code: "timeout" });
    expect(await h.request({ type: "agent_list", id: "list" })).toMatchObject({ agents: [{ state: "failed" }] });
    // Once exit is proven, even exhausted reserves permit read-only stops.
    h.children[0].emit("exit", null, "SIGKILL");
    expect(agent(await h.request({ type: "agent_stop", id: "terminal", agent_id: a.agent_id })).state).toBe("stopped");
  });
  test("failed stop can retry cleanup with a new reserved ID", async () => {
    const h = harness("ready", "never"); const a = agent(await h.launch());
    for (let i = 0; i < 255; i++) await h.request({ type: "agent_launch", id: `invalid${i}`, cwd: join(h.cwd, "missing") });
    expect(await h.request({ type: "agent_stop", id: "fail", agent_id: a.agent_id })).toMatchObject({ code: "timeout" });
    h.children[0].kill = vi.fn().mockImplementation((signal: string) => { queueMicrotask(() => h.children[0].emit("exit", null, signal)); return true; });
    expect(agent(await h.request({ type: "agent_stop", id: "retry", agent_id: a.agent_id })).state).toBe("stopped");
  });
  test("real process stand-in: readiness IPC plus RPC, no prompt, graceful stdin termination", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "managed-agent-real-")); dirs.push(cwd);
    const spawnReal = vi.fn<ManagedSpawn>().mockImplementation((_command, _args, options) => {
      const name = JSON.parse(options?.env?.REMOTE_PI_DIRECT_CONFIG ?? "{}").agent_name as string;
      const script = `process.send(${JSON.stringify({ type: "remote_pi_managed_ready", ok: true, name, room_id: roomIdFor(cwd, name) })});
        require('readline').createInterface({input:process.stdin}).on('line', line=>{ const r=JSON.parse(line); if(r.type!=='get_state') process.exit(2); console.log(JSON.stringify({type:'response',command:'get_state',id:r.id,success:true})); });
        process.stdin.on('end',()=>process.exit(0));`;
      return spawn(process.execPath, ["-e", script], options);
    });
    const m = new ManagedAgents({ cwd, extensionPath: "/extension.js", spawn: spawnReal, readinessMs: 2000 }); managers.push(m);
    const a = agent(await m.handle("owner", { type: "agent_launch", id: "launch", launcher_id: m.launcherId, cwd }, allowed));
    expect(a.state).toBe("running");
    expect(agent(await m.handle("owner", { type: "agent_stop", id: "stop", agent_id: a.agent_id }, allowed)).state).toBe("stopped");
  });
});

test("managedChildEnv strips inherited worker/session/display identities but keeps host discovery", () => {
  const env = managedChildEnv({ PATH: "/bin", PI_SUBAGENT_CHILD: "1", PI_WORKER_ID: "worker", PI_SESSION_ID: "parent", PI_AGENT_ID: "a", PI_PARENT_SESSION: "p", PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT: "parent-package", PI_ASYNC_NATIVE_RUNNER: "worker", PI_SESSION_FILE: "parent.jsonl",
    COCKPIT_PANE_ID: "pane", TUIOS_WINDOW_ID: "window", CMUX_SURFACE_ID: "surface", REMOTE_PI_DIRECT_CONFIG: "parent-config", REMOTE_PI_RELAY: "https://test.invalid" }, "new-child");
  expect(env).toEqual({ PATH: "/bin", REMOTE_PI_RELAY: "https://test.invalid", REMOTE_PI_DAEMON: "1", REMOTE_PI_MANAGED_CHILD: "1", REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: "new-child", auto_start_relay: true }) });
  for (const key of ["PI_SUBAGENT_CHILD", "PI_WORKER_ID", "PI_SESSION_ID", "PI_AGENT_ID", "PI_PARENT_SESSION",
    "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_ASYNC_NATIVE_RUNNER", "PI_SESSION_FILE",
    "COCKPIT_PANE_ID", "TUIOS_WINDOW_ID", "CMUX_SURFACE_ID"]) {
    expect(Object.hasOwn(env, key)).toBe(false);
  }
});

test("session control owned stop uses exact captured child and rechecks late authority before effects", async () => {
  const h = harness(); const record = agent(await h.launch()); const child = h.children[0];
  expect(h.manager.ownsChild("owner-a", record.agent_id, child)).toBe(true);
  expect(await h.manager.stopOwnedChild("other-owner", record.agent_id, child, allowed)).toBe(false);
  expect(await h.manager.stopOwnedChild("owner-a", record.agent_id, new ChildProcess(), allowed)).toBe(false);
  let release!: (ok: boolean) => void;
  const pending = h.manager.stopOwnedChild("owner-a", record.agent_id, child, () => new Promise(resolve => { release = resolve; }));
  child.emit("exit", 0, null); release(true);
  expect(await pending).toBe(false); expect(child.kill).not.toHaveBeenCalled();
  const next = agent(await h.launch("next"));
  expect(await h.manager.stopOwnedChild("owner-a", next.agent_id, child, allowed)).toBe(false);
  expect(await h.manager.stopOwnedChild("owner-a", next.agent_id, h.children[1], allowed)).toBe(true);
  expect(h.children[1].kill).toHaveBeenCalledExactlyOnceWith("SIGTERM");
});

const expectedModel = { provider: "openai-codex", id: "gpt-6.1-sol", api: "openai-codex-responses", contextWindow: 500000, maxTokens: 128000 };
test.each([true, false])("exact model gates publication in either readiness order (bridge first=%s)", async readyFirst => {
  let finishPublication!: () => void;
  const gate = new Promise<void>(r => { finishPublication = r; });
  const dispose = vi.fn();
  const publish = vi.fn(async () => { await gate; return dispose; });
  const h = harness("ready", "SIGTERM", { publish, readinessMs: 1000,
    prepareSpawn: async agent => ({ command: "pi", args: ["--approve"], options: { env: { REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: agent.name }) } }, expectedModel, close: async () => {} }),
  }, expectedModel, readyFirst);
  const result = h.launch(); await expect.poll(() => publish.mock.calls.length).toBe(1);
  // Duplicate child-ready records must not create another room while publication awaits.
  h.children[0].emit("message", { type: "remote_pi_managed_ready", ok: true, name: JSON.parse(h.spawnMock.mock.calls[0][2].env!.REMOTE_PI_DIRECT_CONFIG!).agent_name, room_id: roomIdFor(h.cwd, JSON.parse(h.spawnMock.mock.calls[0][2].env!.REMOTE_PI_DIRECT_CONFIG!).agent_name) });
  finishPublication(); expect(await result).toMatchObject({ type: "agent_launch_result" });
  expect(publish).toHaveBeenCalledTimes(1);
});
test.each([true, false].flatMap(order => [undefined, {}, { ...expectedModel, id: "gpt-5.5" }, { ...expectedModel, api: "openai-responses" }, { ...expectedModel, contextWindow: 272000 }].map(model => ({ order, model }))))("invalid/missing actual model never publishes ($order, $model)", async ({ order, model }) => {
  const publish = vi.fn();
  const h = harness("ready", "SIGTERM", { publish, prepareSpawn: async agent => ({ command: "pi", args: ["--approve"], options: { env: { REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: agent.name }) } }, expectedModel, close: async () => {} }) }, model, order);
  expect(await h.launch()).toMatchObject({ type: "error", message: "Pi did not select the exact configured model; inspect the prepared runtime and configured defaults locally" });
  expect(publish).not.toHaveBeenCalled(); expect(h.children[0].kill).toHaveBeenCalledWith("SIGTERM");
});
test("revocation during publication disposes the room and cleans up the exact child", async () => {
  let granted = true; const dispose = vi.fn();
  const h = harness("ready", "SIGTERM", { admitted: () => granted, publish: async () => { granted = false; return dispose; } });
  expect(await h.launch()).toMatchObject({ type: "error" });
  expect(dispose).toHaveBeenCalledTimes(1); expect(h.children[0].kill).toHaveBeenCalledWith("SIGTERM");
});

test("an authorization exception after publication cannot leak its disposer", async () => {
  let throwAuth = false; const dispose = vi.fn();
  const h = harness("ready", "SIGTERM", { publish: async () => { throwAuth = true; return dispose; } });
  expect(await h.request({ type: "agent_launch", id: "auth-throws", cwd: h.cwd }, "owner-a", async () => { if (throwAuth) throw new Error("private-detail"); return true; })).toMatchObject({ type: "error" });
  expect(dispose).toHaveBeenCalledTimes(1); expect(h.children[0].kill).toHaveBeenCalledWith("SIGTERM");
});

test("missing RPC state cannot publish a bridge-ready prepared child", async () => {
  const publish = vi.fn(), close = vi.fn(async () => {});
  const h = harness("ipc-only", "SIGTERM", { publish, prepareSpawn: async agent => ({ command: "pi", args: ["--approve"], options: { env: { REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: agent.name }) } }, expectedModel, close }) });
  expect(await h.launch()).toMatchObject({ type: "error", code: "timeout" });
  expect(publish).not.toHaveBeenCalled(); expect(close).toHaveBeenCalledTimes(1); expect(h.children[0].kill).toHaveBeenCalledWith("SIGTERM");
});
