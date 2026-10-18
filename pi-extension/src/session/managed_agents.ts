import { isDeepStrictEqual } from "node:util";
import type { ExpectedModel } from "./launch_runtime.js";
import { LaunchPreflightError } from "./launch_preflight.js";
import { ManagedLineDecoder, parseManagedFrame, markPipeChild } from "./managed_pipe.js";
import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import { randomUUID } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";
import type { AgentRequest, ManagedAgent, ServerMessage } from "../protocol/types.js";
import { resolvePiSpawn, rpcSpawnArgs } from "../daemon/rpc_child.js";
import { roomIdFor } from "../rooms.js";
import { sanitizeSegment } from "./local_config.js";

export const MANAGED_CHILD_ENV = "REMOTE_PI_MANAGED_CHILD";
export const MAX_MANAGED_AGENTS = 4;
const MAX_RECORDS = 32;
const MAX_REQUESTS = 256;
const RESERVED_STOPS_PER_AGENT = 3;

/** Keep host credentials/config resolution, not its worker or session identity. */
export function managedChildEnv(parent: NodeJS.ProcessEnv, name: string): NodeJS.ProcessEnv {
  const env = { ...parent };
  for (const key of Object.keys(env)) {
    if (/^PI_(SUBAGENTS?|WORKER|SESSION|PARENT|AGENT)(_|$)/.test(key) || key === "PI_ASYNC_NATIVE_RUNNER" ||
        /^(TUIOS_|COCKPIT_|CMUX_)/.test(key) ||
        ["REMOTE_PI_DIRECT_CONFIG", "REMOTE_PI_DAEMON", "PI_CODING_AGENT_SESSION_DIR", MANAGED_CHILD_ENV].includes(key)) delete env[key];
  }
  env.REMOTE_PI_DAEMON = "1";
  env[MANAGED_CHILD_ENV] = "1";
  env.REMOTE_PI_DIRECT_CONFIG = JSON.stringify({ agent_name: name, auto_start_relay: true });
  return env;
}

interface Entry {
  owner: string;
  agent: ManagedAgent;
  child?: ChildProcess;
  exited: Promise<void>;
  stop?: Promise<void>;
  stopRequested?: boolean;
  reservedStops: number;
  requestId?: string;
  dispose?: () => void;
}
export type ManagedSpawn = (command: string, args: readonly string[], options: SpawnOptions) => ChildProcess;

export interface ManagedOptions {
  cwd: string;
  extensionPath: string;
  piBin?: string;
  readinessMs?: number;
  stopMs?: number;
  spawn?: ManagedSpawn;
  env?: NodeJS.ProcessEnv;
  prepareSpawn?: (agent: ManagedAgent, owner: string, requestId: string) => Promise<{ command: string; args: string[]; options: SpawnOptions; pipe?: boolean; expectedModel?: ExpectedModel; close(): Promise<void> }>;
  admitted?: (owner: string, requestId: string) => boolean;
  publish?: (agent: ManagedAgent, owner: string, child: ChildProcess) => Promise<() => void>;
}
class AgentFailure extends Error {
  constructor(readonly code: "invalid_message" | "rate_limited" | "timeout" | "internal_error", message: string) { super(message); }
}

/** Session-owned, never registered with supervisord, never automatically restarted.
 * Retain all accepted idempotency keys; once bounded history fills, reject new
 * mutations rather than evicting a key and accidentally launching its replay.
 */
export class ManagedAgents {
  /** Incarnation of the host session and its idempotency history. */
  readonly launcherId = randomUUID();
  private readonly entries = new Map<string, Entry>();
  private readonly requests = new Map<string, { payload: string; result: Promise<ServerMessage> }>();
  private ordinaryRequests = 0;
  private closing = false;
  private readonly killAtExit = () => {
    for (const entry of this.entries.values()) { try { entry.child?.kill("SIGKILL"); } catch { /* already gone */ } }
  };

  constructor(private readonly opts: ManagedOptions) { process.once("exit", this.killAtExit); }

  async handle(owner: string, request: AgentRequest, authorized: () => Promise<boolean>): Promise<ServerMessage> {
    const error = (code: "invalid_message" | "rate_limited" | "timeout" | "internal_error", message: string): ServerMessage =>
      ({ type: "error", in_reply_to: request.id, code, message });
    if (request.type === "agent_launch" && request.launcher_id !== this.launcherId) {
      return Promise.resolve(error("invalid_message", "Launching session changed; refresh and confirm a new Start"));
    }
    const key = JSON.stringify([owner, request.id]);
    let payload: string;
    switch (request.type) {
      case "agent_launch":
        payload = JSON.stringify([request.type, request.launcher_id, request.cwd, request.name ?? null]);
        break;
      case "agent_stop":
        payload = JSON.stringify([request.type, request.agent_id]);
        break;
      case "agent_list":
        payload = JSON.stringify([request.type]);
        break;
      default:
        return error("invalid_message", "Unsupported agent request type");
    }
    try {
      if (this.closing || !await authorized()) return error("invalid_message", "Launcher closed or Owner no longer paired");
    } catch { return error("internal_error", "Could not verify Owner pairing"); }
    if (this.closing) return error("invalid_message", "Launcher closed");
    const previous = this.requests.get(key);
    if (previous) return previous.payload === payload ? previous.result : error("invalid_message", "Request ID already used with a different payload");
    // Read-only snapshots are fresh and never consume mutation history. Any
    // retained mutation ID still takes precedence for replay/conflict checks.
    if (request.type === "agent_list") return {
      type: "agent_list_result", in_reply_to: request.id, available: true, launcher_id: this.launcherId,
      cwd: this.opts.cwd, max_agents: MAX_MANAGED_AGENTS,
      agents: [...this.entries.values()].flatMap(e => e.owner === owner ? [{ ...e.agent }] : []),
    };
    const stopEntry = request.type === "agent_stop" ? this.entries.get(request.agent_id) : undefined;
    if (request.type === "agent_stop" && (!stopEntry || stopEntry.owner !== owner)) {
      return error("invalid_message", "Unknown agent or not owned by this Owner");
    }
    if (stopEntry && !stopEntry.child && stopEntry.agent.state !== "starting") {
      this.markStopped(stopEntry);
      return { type: "agent_stop_result", in_reply_to: request.id, agent: { ...stopEntry.agent } };
    }
    // Preserve cleanup capacity after normal history fills. Invalid/unowned
    // targets above never spend the per-record reserve. Failed attempts stay
    // replayable; a new ID retries cleanup up to this explicit bounded limit.
    if (this.ordinaryRequests >= MAX_REQUESTS) {
      if (!stopEntry) return error("rate_limited", "Launcher mutation history is full; start a new host session");
      if (stopEntry.reservedStops >= RESERVED_STOPS_PER_AGENT) return error("rate_limited", "Cleanup retry history exhausted; shut down the host session and inspect the host if Pi remains alive");
      stopEntry.reservedStops += 1;
    } else this.ordinaryRequests += 1;
    const result = (async (): Promise<ServerMessage> => {
      try {
        if (this.closing) throw new AgentFailure("invalid_message", "Launcher closed");
        if (request.type === "agent_launch") {
          const agent = await this.launch(owner, request, authorized);
          return { type: "agent_launch_result", in_reply_to: request.id, agent: { ...agent } };
        }
        const entry = this.entries.get(request.agent_id);
        if (!entry || entry.owner !== owner) throw new AgentFailure("invalid_message", "Unknown agent or not owned by this Owner");
        if (!await authorized() || this.closing || this.opts.admitted?.(owner, request.id) === false) throw new AgentFailure("invalid_message", "Control authority changed");
        await this.stop(entry);
        return { type: "agent_stop_result", in_reply_to: request.id, agent: { ...entry.agent } };
      } catch (err) {
        return error(err instanceof AgentFailure ? err.code : "internal_error",
          err instanceof AgentFailure ? err.message : "Agent operation failed; check the host Pi installation and directory access");
      }
    })();
    this.requests.set(key, { payload, result });
    return result;
  }

  private async launch(owner: string, request: Extract<AgentRequest, { type: "agent_launch" }>, authorized: () => Promise<boolean>): Promise<ManagedAgent> {
    let cwd: string;
    try {
      cwd = await realpath(resolve(this.opts.cwd, request.cwd));
      if (!(await stat(cwd)).isDirectory()) throw new Error("not directory");
    } catch { throw new AgentFailure("invalid_message", "Directory does not exist, is inaccessible, or is not a directory"); }
    const label = request.name ? sanitizeSegment(request.name) : "phone-agent";
    if (!label) throw new AgentFailure("invalid_message", "Name is not a usable agent label");
    if (!await authorized() || this.closing) throw new AgentFailure("invalid_message", "Launcher closed or Owner no longer paired");
    // No awaits between admission and inserting a starting record: parallel
    // launches share the same global live-process and retained-record bounds.
    if ([...this.entries.values()].filter(e => e.child || e.agent.state === "starting").length >= MAX_MANAGED_AGENTS) {
      throw new AgentFailure("rate_limited", "Maximum of 4 managed agents reached; stop one first");
    }
    if (this.entries.size >= MAX_RECORDS) throw new AgentFailure("rate_limited", "Launcher history is full (32 agents); start a new host session");
    const id = randomUUID();
    const name = `${label}-${id}`;
    const agent: ManagedAgent = { agent_id: id, name, cwd, room_id: roomIdFor(cwd, name), state: "starting" };
    const entry: Entry = { owner, agent, exited: Promise.resolve(), reservedStops: 0, requestId: request.id };
    this.entries.set(id, entry);
    try {
      await this.start(entry, authorized);
      if (this.closing || !await authorized() || this.opts.admitted?.(owner, request.id) === false) throw new AgentFailure("invalid_message", "Launcher closed or Owner revoked during startup");
      if (!entry.child || entry.stopRequested) throw new AgentFailure("internal_error", "Pi stopped or exited during startup");
      entry.agent.state = "running";
      return entry.agent;
    } catch (err) {
      if (!entry.stopRequested) {
        entry.agent.state = "failed";
        entry.agent.error = err instanceof AgentFailure ? err.message : "Pi startup failed unexpectedly; inspect the host launcher locally and refresh status before retrying";
      }
      try { await this.cleanupChild(entry); } catch { entry.agent.error = (entry.agent.error ?? "Startup stopped") + "; cleanup failed — host shutdown will retry"; }
      throw err instanceof AgentFailure ? err : new AgentFailure("internal_error", entry.agent.error ?? "Startup stopped");
    }
  }

  private async start(entry: Entry, authorized: () => Promise<boolean>): Promise<void> {
    const prepared = await this.opts.prepareSpawn?.(entry.agent, entry.owner, entry.requestId!).catch(error => {
      if (error instanceof LaunchPreflightError) throw new AgentFailure("invalid_message", error.message);
      throw error;
    });
    try {
      if (!await authorized() || this.closing || entry.stopRequested || this.opts.admitted?.(entry.owner, entry.requestId!) === false) throw new AgentFailure("invalid_message", "Launch authority changed");
      return await new Promise<void>((resolveReady, reject) => {
      const target = resolvePiSpawn(this.opts.piBin ?? "pi");
      const child = (this.opts.spawn ?? spawn)(prepared?.command ?? target.command,
        prepared?.args ?? [...target.prefixArgs, ...rpcSpawnArgs(this.opts.extensionPath, entry.agent.name, false)],
        prepared?.options ?? { cwd: entry.agent.cwd, env: managedChildEnv(this.opts.env ?? process.env, entry.agent.name),
          stdio: ["pipe", "pipe", "pipe", "ipc"], windowsHide: true });
      entry.child = child;
      if (prepared?.pipe) markPipeChild(child);
      let rpcReady = false;
      let settled = false;
      let buf = "";
      const timer = setTimeout(() => finish(new AgentFailure("timeout", "Pi startup timed out; check project extensions, relay connectivity and host identity storage")), this.opts.readinessMs ?? 20_000);
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error) reject(error);
        else resolveReady();
      };
      let bridgeReady = false;
      let publishing = false;
      const current = () => !settled && !!entry.child && !entry.stopRequested && !this.closing && this.opts.admitted?.(entry.owner, entry.requestId!) !== false;
      const checkReady = () => {
        if (!bridgeReady || !rpcReady || publishing || !current()) return;
        publishing = true;
        void (async () => {
          if (!await authorized() || !current()) throw new AgentFailure("invalid_message", "Launch authority changed before publication");
          const dispose = await this.opts.publish?.(entry.agent, entry.owner, child);
          let adopted = false;
          try {
            if (!current() || !await authorized() || !current()) throw new AgentFailure("invalid_message", "Launch authority changed during publication");
            entry.dispose = dispose; adopted = true; finish();
          } finally { if (!adopted) dispose?.(); }
        })().catch(error => finish(error instanceof AgentFailure ? error : new AgentFailure("internal_error", "Could not publish managed room")));
      };
      entry.exited = new Promise<void>((resolveExit) => {
        child.once("exit", (code, signal) => {
          entry.child = undefined;
          entry.dispose?.(); entry.dispose = undefined;
          if (entry.agent.state !== "stopped" && !entry.stop) {
            entry.agent.state = "failed";
            entry.agent.error = `Pi exited (code ${code ?? "none"}, signal ${signal ?? "none"}); no automatic restart`;
          }
          finish(new AgentFailure("internal_error", entry.agent.error ?? "Pi exited before readiness"));
          resolveExit();
        });
        child.once("error", (err: NodeJS.ErrnoException) => {
          if (!child.pid) { entry.child = undefined; resolveExit(); }
          finish(new AgentFailure("internal_error", prepared
            ? "Secure sandbox process could not start; inspect local bubblewrap runtime and project permissions"
            : err.code === "ENOENT"
            ? "Pi executable not found; install Pi and make it available on the host PATH"
            : "Unable to start Pi; check executable and directory permissions"));
        });
      });
      child.stdin?.on("error", () => { finish(new AgentFailure("internal_error", "Pi RPC input closed during startup")); if (prepared?.pipe) child.kill("SIGKILL"); });
      if (prepared?.pipe) child.stdout?.once("end", () => { if (entry.child) child.kill("SIGKILL"); });
      // Never forward project logs (which may contain secrets). Drain stderr;
      // retain no logs, and bound the partial JSON line buffer on stdout.
      child.stderr?.on("data", () => {});
      const decoder = new ManagedLineDecoder();
      const consume = (chunk: Buffer) => {
        buf += chunk.toString();
        if (buf.length > 65_536) { buf = ""; finish(new AgentFailure("internal_error", "Pi startup output exceeded the RPC line limit")); return; }
        let end: number;
        while ((end = buf.indexOf("\n")) !== -1) {
          const line = buf.slice(0, end); buf = buf.slice(end + 1);
          try {
            const data = JSON.parse(line) as { type?: string; command?: string; id?: string; success?: boolean; data?: { model?: Record<string, unknown> } };
            if (data.type === "response" && data.command === "get_state" && data.id === entry.agent.agent_id && data.success === true) {
              if (prepared?.expectedModel) {
                const actual = data.data?.model, expected = prepared.expectedModel;
                if (!actual || (["provider", "id", "api", "contextWindow", "maxTokens", "compat", "thinkingLevelMap", "reasoning", "input"] as const).some(key => !isDeepStrictEqual(actual[key], expected[key]))) {
                  finish(new AgentFailure("invalid_message", "Pi did not select the exact configured model; inspect the prepared runtime and configured defaults locally"));
                  continue;
                }
              }
              rpcReady = true; checkReady();
            }
          } catch { /* bounded non-RPC extension output */ }
        }
      };
      child.stdout?.on("data", (chunk: Buffer) => {
        if (!prepared?.pipe) { consume(chunk); return; }
        try { decoder.push(chunk, line => {
          const managed = parseManagedFrame(line);
          if (managed !== undefined) {
            const kind = (managed as { type?: unknown }).type;
            if (kind !== "remote_pi_managed_ready" && kind !== "managed_event" && kind !== "managed_metadata") throw new Error("Invalid child frame direction");
            child.emit("message", managed);
          } else consume(Buffer.from(line));
        }); } catch { finish(new AgentFailure("invalid_message", "Invalid managed pipe frame")); child.kill("SIGKILL"); }
      });
      child.on("message", (message: unknown) => {
        const m = message as { type?: unknown; name?: unknown; room_id?: unknown; ok?: unknown } | null;
        if (m?.type !== "remote_pi_managed_ready") return;
        if (m.ok !== true || m.name !== entry.agent.name || m.room_id !== entry.agent.room_id) {
          finish(new AgentFailure("internal_error", "Child could not publish its independent room; check relay, identity storage and name admission"));
        } else { bridgeReady = true; checkReady(); }
      });
      child.once("spawn", () => {
        child.stdin?.write(JSON.stringify({ type: "get_state", id: entry.agent.agent_id }) + "\n");
      });
    }); } finally { await prepared?.close(); }
  }

  private markStopped(entry: Entry): void {
    const { error: _error, ...agent } = entry.agent;
    entry.agent = { ...agent, state: "stopped" };
  }

  private async stop(entry: Entry): Promise<void> {
    entry.stopRequested = true;
    await this.cleanupChild(entry);
    this.markStopped(entry);
  }

  /** Terminate without changing the record; only successful explicit Stop finalizes it. */
  private cleanupChild(entry: Entry): Promise<void> {
    if (entry.stop) return entry.stop;
    if (!entry.child) return Promise.resolve();
    entry.stop = this.terminateChild(entry, entry.child)
      .finally(() => { entry.stop = undefined; });
    return entry.stop;
  }

  private async terminateChild(entry: Entry, child: ChildProcess): Promise<void> {
    const delay = this.opts.stopMs ?? 3_000;
    const wait = async () => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const result = await Promise.race([entry.exited, new Promise<false>(r => { timer = setTimeout(() => r(false), delay); })]);
      clearTimeout(timer); return result !== false;
    };
    child.stdin?.end();
    child.kill("SIGTERM");
    if (!await wait()) { child.kill("SIGKILL"); if (!await wait()) throw new AgentFailure("timeout", "Pi did not exit after SIGKILL; host shutdown will retry cleanup"); }
  }

  /** Captured owned process only; never resolve a replacement by PID/name/cwd. */
  ownsChild(owner: string, agentId: string, child: ChildProcess): boolean {
    const entry = this.entries.get(agentId);
    return !this.closing && !!entry && entry.owner === owner && entry.child === child && !entry.stopRequested;
  }
  async stopOwnedChild(owner: string, agentId: string, child: ChildProcess, authorized: () => Promise<boolean>): Promise<boolean> {
    if (!await authorized() || !this.ownsChild(owner, agentId, child)) return false;
    const entry = this.entries.get(agentId)!;
    await this.stop(entry);
    return !entry.child && entry.agent.state === "stopped";
  }

  async shutdownOwner(owner: string): Promise<boolean> {
    const owned = [...this.entries.values()].filter(entry => entry.owner === owner);
    const results = await Promise.allSettled(owned.map(entry => this.stop(entry)));
    return results.every(r => r.status === "fulfilled") && !owned.some(e => e.child || e.agent.state === "starting");
  }

  async shutdown(): Promise<void> {
    this.closing = true;
    await Promise.all([...this.entries.values()].map(async entry => {
      try { await this.stop(entry); } catch { /* exit hook + IPC disconnect remain last-resort guards */ }
      return undefined;
    }));
    if (![...this.entries.values()].some(e => e.child)) process.off("exit", this.killAtExit);
  }
}
