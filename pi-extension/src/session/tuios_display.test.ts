import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { RoomDisplay } from "../transport/relay_client.js";

const exec = vi.hoisted(() => vi.fn());
vi.mock("node:child_process", () => ({ execFile: exec }));
import {
  TuiosDisplayAdapter, ownTuiosWindow, sanitizeDisplayName, queryTuios,
  DISPLAY_OUTPUT_BYTES, DISPLAY_POLL_MS, DISPLAY_QUERY_TIMEOUT_MS,
  type DisplayQuery,
} from "./tuios_display.js";

const A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const W = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const candidate = { session: "work", windowId: W };
const env = { TUIOS_ENV: "1", TUIOS_SESSION: "work", TUIOS_WINDOW_ID: W, TUIOS_PANE_ID: W };
const state = (id = A) => JSON.stringify({ agent_session_id: id });
const window = (name: string | null) => JSON.stringify({ custom_name: name, title: "volatile", display_name: "ignored", cwd: "/duplicate" });
const injectedClock = {
  setTimeout: (callback: () => void, ms: number) => setTimeout(callback, ms),
  clearTimeout: (timer: unknown) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

async function drain() { for (let n = 0; n < 20; n++) await Promise.resolve(); }
function harness(query: DisplayQuery, id = A) {
  const updates: RoomDisplay[] = [];
  let current = true;
  const adapter = new TuiosDisplayAdapter({ nativeSessionId: id, candidate, query, clock: injectedClock });
  adapter.activate({ isCurrent: () => current, publish: d => updates.push(d) });
  return { adapter, updates, retire: () => { current = false; } };
}
function metadataQuery() {
  let name: string | null = "Pi · system";
  let uuid = A;
  const query = vi.fn(async (args: readonly string[]) => args[0] === "get-agent-state" ? state(uuid) : window(name));
  return { query, rename: (value: string | null) => { name = value; }, setUuid: (id: string) => { uuid = id; } };
}

beforeEach(() => { vi.useFakeTimers(); exec.mockReset(); });
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe("TuiosDisplayAdapter exact display scope", () => {
  test("endpoint distinguishes verified null reset from unavailable/inflight/stale scope and deactivation", async () => {
    const source = metadataQuery(); source.rename(null);
    const h = harness(source.query);
    expect(h.adapter.endpointSnapshot()).toBeNull();
    await drain();
    expect(h.adapter.endpointSnapshot()).toEqual({ native_session_id: A, epoch: expect.any(String), revision: 0, name: null });
    source.rename("Renamed"); await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(h.adapter.endpointSnapshot()).toEqual({ ...h.adapter.snapshot(), revision: 1, name: "Renamed" });
    source.setUuid(B); await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(h.adapter.endpointSnapshot()).toBeNull();
    source.setUuid(A); h.adapter.activate({ isCurrent: () => true, publish: () => {} });
    expect(h.adapter.endpointSnapshot()).toBeNull(); await drain();
    expect(h.adapter.endpointSnapshot()?.name).toBe("Renamed");
    h.adapter.deactivate(); expect(h.adapter.endpointSnapshot()).toBeNull();
    const missing = new TuiosDisplayAdapter({ nativeSessionId: A, query: source.query });
    missing.activate({ isCurrent: () => true, publish: () => {} }); await drain();
    expect(missing.endpointSnapshot()).toBeNull(); missing.deactivate();
    const stale = harness(source.query); await drain(); stale.retire();
    expect(stale.adapter.endpointSnapshot()).toBeNull(); stale.adapter.deactivate();
  });

  test("constructor is inert, hello seeds null, rename/reset/dedup preserve epoch and bound polling", async () => {
    const source = metadataQuery();
    const adapter = new TuiosDisplayAdapter({ nativeSessionId: A, candidate, query: source.query, clock: injectedClock });
    const seed = adapter.snapshot();
    expect(seed).toEqual({ native_session_id: A, epoch: expect.any(String), revision: 0, name: null });
    expect(source.query).not.toHaveBeenCalled();
    const updates: RoomDisplay[] = [];
    adapter.activate({ isCurrent: () => true, publish: d => updates.push(d) });
    await drain();
    expect(updates).toEqual([{ ...seed, revision: 1, name: "Pi · system" }]);
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS - 1);
    expect(source.query).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(updates).toHaveLength(1);
    source.rename("Android label");
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    source.rename(null);
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(updates.slice(1)).toEqual([
      { ...seed, revision: 2, name: "Android label" },
      { ...seed, revision: 3, name: null },
    ]);
    expect(source.query.mock.calls.slice(0, 3).map(c => c[0])).toEqual([
      ["get-agent-state", "-s", "work", "-w", W, "--json"],
      ["get-window", W, "-s", "work", "--json"],
      ["get-agent-state", "-s", "work", "-w", W, "--json"],
    ]);
    adapter.deactivate();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("wrong UUID/inherited parent never reads a name; cwd/title are irrelevant", async () => {
    const source = metadataQuery();
    source.setUuid(B);
    const h = harness(source.query);
    await drain();
    expect(source.query).toHaveBeenCalledTimes(1);
    expect(h.updates).toEqual([]);
    expect(h.adapter.snapshot().name).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("both UUID reads must match; transient stale binding clears a previously verified name", async () => {
    const source = metadataQuery();
    const h = harness(source.query);
    await drain();
    source.query.mockResolvedValueOnce(state()).mockResolvedValueOnce(window("foreign"))
      .mockResolvedValueOnce(state(B));
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(h.updates.map(d => d.name)).toEqual(["Pi · system", null]);
    expect(vi.getTimerCount()).toBe(0);
  });

  test.each(["missing CLI", "forbidden", "agents_disabled", "closed window", "boot gap", "timeout"])("%s tombstones and ceases retry", async (failure) => {
    const source = metadataQuery();
    const h = harness(source.query);
    await drain();
    source.query.mockRejectedValueOnce(new Error(failure));
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS * 10);
    expect(h.updates.map(d => d.name)).toEqual(["Pi · system", null]);
    expect(source.query).toHaveBeenCalledTimes(4);
    h.adapter.deactivate();
  });

  test.each(["not json", "[]", "null", "{}", JSON.stringify({ agent_session_id: B }), "x".repeat(DISPLAY_OUTPUT_BYTES + 1)])("invalid/capped agent metadata uses null", async (raw) => {
    const query = vi.fn(async () => raw);
    const h = harness(query);
    await drain();
    expect(h.adapter.snapshot().name).toBeNull();
    expect(h.updates).toEqual([]);
    expect(query).toHaveBeenCalledTimes(1);
  });

  test.each([{}, { title: "OSC only", display_name: "not manual" }, { custom_name: 42 }])("invalid own window metadata never falls back to title", async (data) => {
    const query = vi.fn<DisplayQuery>().mockResolvedValueOnce(state()).mockResolvedValueOnce(JSON.stringify(data));
    const h = harness(query);
    await drain();
    expect(h.adapter.snapshot().name).toBeNull();
    expect(query).toHaveBeenCalledTimes(2);
  });

  test.each([1, 2, 3])("room/native switch at query await %i discards work before further reads/publish", async (at) => {
    let release!: (raw: string) => void;
    let calls = 0;
    const query = vi.fn<DisplayQuery>(async (args) => {
      calls++;
      if (calls === at) return new Promise<string>(resolve => { release = resolve; });
      return args[0] === "get-agent-state" ? state() : window("late");
    });
    const h = harness(query);
    await drain();
    h.retire();
    release(at === 2 ? window("late") : state());
    await drain();
    expect(query).toHaveBeenCalledTimes(at);
    expect(h.updates).toEqual([]);
    h.adapter.deactivate();
  });

  test("stop aborts, repeated activations drain canceled work and never overlap queries", async () => {
    let release!: (raw: string) => void;
    let signal!: AbortSignal;
    const query = vi.fn<DisplayQuery>().mockImplementationOnce(async (_args, s) => {
      signal = s;
      return new Promise(resolve => { release = resolve; });
    }).mockImplementation(async args => args[0] === "get-agent-state" ? state() : window("new"));
    const h = harness(query);
    await drain();
    h.adapter.deactivate();
    expect(signal.aborted).toBe(true);
    h.adapter.activate({ isCurrent: () => true, publish: d => h.updates.push(d) });
    h.adapter.activate({ isCurrent: () => true, publish: d => h.updates.push(d) });
    await drain();
    expect(query).toHaveBeenCalledTimes(1);
    release(state());
    await drain();
    expect(query).toHaveBeenCalledTimes(4);
    expect(h.updates.map(d => d.name)).toEqual(["new"]);
    h.adapter.deactivate();
  });

  test("bounded revisions reserve the final safe integer for a null tombstone", async () => {
    const source = metadataQuery();
    const h = harness(source.query);
    await drain();
    const nearLimit = { ...h.adapter.snapshot(), revision: Number.MAX_SAFE_INTEGER - 1 };
    // Synthetic exhaustion fixture; production has no revision override API.
    Object.defineProperty(h.adapter, "display", { value: nearLimit, writable: true });
    source.rename("cannot advance to another live alias");
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(h.adapter.snapshot()).toEqual({ ...nearLimit, revision: Number.MAX_SAFE_INTEGER, name: null });
    expect(Number.isSafeInteger(h.adapter.snapshot().revision)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
    h.adapter.deactivate();
  });

  test("transport publication failure retains snapshot without rejecting the query chain", async () => {
    const source = metadataQuery();
    const adapter = new TuiosDisplayAdapter({ nativeSessionId: A, candidate, query: source.query });
    adapter.activate({ isCurrent: () => true, publish: () => { throw new Error("WS closed"); } });
    await drain();
    expect(adapter.snapshot().name).toBe("Pi · system");
    adapter.deactivate();
    const updates: RoomDisplay[] = [];
    source.rename(null);
    adapter.activate({ isCurrent: () => true, publish: d => updates.push(d) });
    await drain();
    expect(updates.map(d => d.name)).toEqual([null]);
    adapter.deactivate();
  });

  test("A-B-A/reload create distinct fresh epochs even for same UUID", () => {
    const adapters = [A, B, A, A].map(nativeSessionId => new TuiosDisplayAdapter({ nativeSessionId }));
    expect(new Set(adapters.map(a => a.snapshot().epoch)).size).toBe(4);
    expect(adapters.every(a => a.snapshot().revision === 0 && a.snapshot().name === null)).toBe(true);
  });

  test("reconnect preserves exact cached identity but revalidates before publishing", async () => {
    const source = metadataQuery();
    const h = harness(source.query);
    await drain();
    const cached = h.adapter.snapshot();
    h.adapter.deactivate();
    await vi.advanceTimersByTimeAsync(20_000);
    expect(source.query).toHaveBeenCalledTimes(3);
    expect(h.adapter.snapshot()).toEqual(cached);
    h.adapter.activate({ isCurrent: () => true, publish: d => h.updates.push(d) });
    await drain();
    expect(h.updates).toHaveLength(1);
    source.rename("");
    await vi.advanceTimersByTimeAsync(DISPLAY_POLL_MS);
    expect(h.adapter.snapshot()).toEqual({ ...cached, revision: 2, name: null });
    h.adapter.deactivate();
  });
});

describe("ownTuiosWindow", () => {
  test("full own identifiers only; managed child always excluded", () => {
    expect(ownTuiosWindow(env, "tui")).toEqual(candidate);
    for (const patch of [
      { PI_SUBAGENT_CHILD: "1" }, { TUIOS_ENV: undefined }, { TUIOS_WINDOW_ID: "cccc" },
      { TUIOS_PANE_ID: B }, { TUIOS_SESSION: "host:work" }, { TUIOS_SESSION: "bad\n" },
      { TUIOS_SESSION: undefined },
    ]) expect(ownTuiosWindow({ ...env, ...patch }, "tui")).toBeUndefined();
    expect(ownTuiosWindow(env, "rpc")).toBeUndefined();
  });
  test("no candidate runs no CLI/timer even when active", async () => {
    const query = vi.fn<DisplayQuery>();
    const adapter = new TuiosDisplayAdapter({ nativeSessionId: A, query });
    adapter.activate({ isCurrent: () => true, publish: vi.fn() });
    await drain();
    expect(query).not.toHaveBeenCalled();
    expect(exec).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe("bounded CLI and plain text", () => {
  test("sanitizes terminal/bidi/control sequences and bounds Unicode length", () => {
    expect(sanitizeDisplayName(" \x1b[31mPi ·\n system\x1b[0m\u202e ")).toBe("Pi · system");
    expect(sanitizeDisplayName("\x1b]0;task\x07manual")).toBe("manual");
    expect(Array.from(sanitizeDisplayName("😀".repeat(200))!).length).toBe(128);
    expect(sanitizeDisplayName("\n\u200b")).toBeNull();
    expect(() => sanitizeDisplayName(undefined)).toThrow();
  });
  test("query uses execFile argument array with timeout/cap/kill/abort, never shell", async () => {
    exec.mockImplementation((_bin, _args, _opts, callback) => { callback(null, "{}"); });
    const signal = new AbortController().signal;
    await expect(queryTuios(["get-window", W, "-s", "work", "--json"], signal)).resolves.toBe("{}");
    expect(exec).toHaveBeenCalledWith("tuios", ["get-window", W, "-s", "work", "--json"], {
      shell: false, windowsHide: true, encoding: "utf8", timeout: DISPLAY_QUERY_TIMEOUT_MS,
      maxBuffer: DISPLAY_OUTPUT_BYTES, killSignal: "SIGKILL", signal,
    }, expect.any(Function));
  });
  test.each(["ENOENT", "timeout", "maxBuffer exceeded", "forbidden"])("CLI %s error never exposes payload", async (message) => {
    exec.mockImplementation((_bin, _args, _opts, callback) => { callback(new Error(message), "sensitive"); });
    await expect(queryTuios([], new AbortController().signal)).rejects.toThrow("tuios display unavailable");
  });
});
