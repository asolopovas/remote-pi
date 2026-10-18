import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { RoomDisplay } from "../transport/relay_client.js";

export const DISPLAY_POLL_MS = 2_000;
export const DISPLAY_QUERY_TIMEOUT_MS = 2_000;
export const DISPLAY_OUTPUT_BYTES = 64 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface TuiosWindowCandidate { session: string; windowId: string }

/** Environment is only an exact candidate address, never ownership proof. */
export function ownTuiosWindow(
  env: NodeJS.ProcessEnv,
  mode: string | undefined,
): TuiosWindowCandidate | undefined {
  if (mode !== "tui" || env.PI_SUBAGENT_CHILD === "1" || env.TUIOS_ENV !== "1") return;
  const windowId = env.TUIOS_WINDOW_ID ?? env.TUIOS_PANE_ID;
  const session = env.TUIOS_SESSION;
  if (!windowId || !UUID.test(windowId) || !session || session.length > 256 ||
      /[\p{Cc}\p{Cf}]/u.test(session) || session.includes(":")) return;
  if (env.TUIOS_PANE_ID && env.TUIOS_PANE_ID !== windowId) return;
  return { session, windowId };
}

export type DisplayQuery = (args: readonly string[], signal: AbortSignal) => Promise<string>;
export interface DisplayClock {
  setTimeout(callback: () => void, ms: number): ReturnType<typeof setTimeout>;
  clearTimeout(timer: ReturnType<typeof setTimeout>): void;
}
const clock: DisplayClock = {
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (timer) => clearTimeout(timer),
};

/** No shell, no alternate daemon discovery, no stderr/body logging. */
export const queryTuios: DisplayQuery = (args, signal) => new Promise((resolve, reject) => {
  execFile("tuios", [...args], {
    shell: false,
    windowsHide: true,
    encoding: "utf8",
    timeout: DISPLAY_QUERY_TIMEOUT_MS,
    maxBuffer: DISPLAY_OUTPUT_BYTES,
    killSignal: "SIGKILL",
    signal,
  }, (error, stdout) => {
    if (error) reject(new Error("tuios display unavailable"));
    else resolve(stdout);
  });
});

function object(raw: string): Record<string, unknown> {
  if (Buffer.byteLength(raw, "utf8") > DISPLAY_OUTPUT_BYTES) throw new Error("display output capped");
  const value: unknown = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("display metadata invalid");
  return value as Record<string, unknown>;
}

export function sanitizeDisplayName(value: unknown): string | null {
  if (value === null || value === "") return null;
  if (typeof value !== "string") throw new Error("custom_name missing");
  // Strip terminal sequences before controls, bidi/format controls and line breaks.
  const plain = value.replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, "").trim();
  return Array.from(plain).slice(0, 128).join("") || null;
}

interface DisplayScope {
  isCurrent(): boolean;
  publish(display: RoomDisplay): void;
}
export interface TuiosDisplayOptions {
  nativeSessionId: string;
  candidate?: TuiosWindowCandidate;
  epoch?: string;
  query?: DisplayQuery;
  clock?: DisplayClock;
}

/** Display scope only: UUID/epoch never authorizes history, routing or tasks.
 * Polling avoids assuming custom-name/reset event coverage. Only a successful
 * exact UUID sandwich arms another cycle; failures tombstone and stop retries.
 */
export class TuiosDisplayAdapter {
  private display: RoomDisplay;
  private available = false;
  private readonly query: DisplayQuery;
  private readonly clock: DisplayClock;
  private generation = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private controller: AbortController | undefined;
  private scope: DisplayScope | undefined;
  // A replacement activation waits for canceled CLI work to drain as well.
  private inFlight: Promise<void> = Promise.resolve();

  constructor(private readonly options: TuiosDisplayOptions) {
    if (!UUID.test(options.nativeSessionId)) throw new Error("native display UUID invalid");
    this.display = {
      native_session_id: options.nativeSessionId,
      epoch: options.epoch ?? randomUUID(),
      revision: 0,
      name: null,
    };
    this.query = options.query ?? queryTuios;
    this.clock = options.clock ?? clock;
  }

  snapshot(): RoomDisplay { return { ...this.display }; }

  /** Endpoint null means unavailable; object name:null is a verified reset. */
  endpointSnapshot(): RoomDisplay | null {
    return this.available && this.scope?.isCurrent() ? this.snapshot() : null;
  }

  activate(scope: DisplayScope): void {
    this.deactivate();
    this.scope = scope;
    const generation = this.generation;
    if (!this.options.candidate) return;
    this.inFlight = this.inFlight.then(() => this.cycle(generation, scope));
  }

  /** Retain the exact identity/revision for reconnect, revoke async authority. */
  deactivate(): void {
    this.available = false;
    this.generation += 1;
    this.scope = undefined;
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer);
    this.timer = undefined;
    this.controller?.abort();
    this.controller = undefined;
  }

  private current(generation: number, scope: DisplayScope): boolean {
    return this.generation === generation && this.scope === scope && scope.isCurrent();
  }

  private async cycle(generation: number, scope: DisplayScope): Promise<void> {
    if (!this.current(generation, scope)) return;
    const candidate = this.options.candidate!;
    const controller = new AbortController();
    this.controller = controller;
    const stateArgs = ["get-agent-state", "-s", candidate.session, "-w", candidate.windowId, "--json"];
    let verified = false;
    let name: string | null = null;
    const read = async (args: string[]): Promise<Record<string, unknown>> => {
      if (!this.current(generation, scope)) throw new Error("stale display scope");
      const raw = await this.query(args, controller.signal);
      if (!this.current(generation, scope)) throw new Error("stale display scope");
      return object(raw);
    };
    try {
      const before = await read(stateArgs);
      if (before.agent_session_id !== this.display.native_session_id) throw new Error("unverified window");
      const window = await read(["get-window", candidate.windowId, "-s", candidate.session, "--json"]);
      name = sanitizeDisplayName(window.custom_name);
      const after = await read(stateArgs);
      if (after.agent_session_id !== this.display.native_session_id) throw new Error("unverified window");
      verified = true;
    } catch {
      name = null;
    } finally {
      if (this.controller === controller) this.controller = undefined;
    }
    if (!this.current(generation, scope)) return;
    this.available = verified;
    if (name !== this.display.name) {
      // Never wrap or emit unsafe revisions. Reserve the final safe revision
      // for a truthful fallback, then stop this incarnation's polling.
      if (this.display.revision >= Number.MAX_SAFE_INTEGER - 1) {
        name = null;
        verified = false;
        this.available = false;
      }
      if (this.display.revision < Number.MAX_SAFE_INTEGER && name !== this.display.name) {
        this.display = { ...this.display, revision: this.display.revision + 1, name };
        if (!this.current(generation, scope)) return;
        try { scope.publish(this.snapshot()); }
        catch { /* best-effort transport; next hello replays the cached snapshot */ }
      }
    }
    if (!verified || !this.current(generation, scope)) return;
    this.timer = this.clock.setTimeout(() => {
      this.timer = undefined;
      if (!this.current(generation, scope)) return;
      this.inFlight = this.inFlight.then(() => this.cycle(generation, scope));
    }, DISPLAY_POLL_MS);
  }
}
