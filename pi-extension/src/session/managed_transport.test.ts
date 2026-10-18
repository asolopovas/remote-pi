import { test, expect, vi, afterEach } from "vitest";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LaunchSecurity, setupLaunchPin } from "./launch_security.js";
import { readFileSync } from "node:fs";
import { generateEd25519Keypair } from "../pairing/crypto.js";

const sockets: MockWS[] = [];
class MockWS extends EventEmitter {
  static OPEN = 1;
  readyState = 1;
  bufferedAmount = 0;
  maxBuffered = 0;
  stall = false;
  throwSend = false;
  callbackError = false;
  sent: string[] = [];
  callbacks: (() => void)[] = [];
  constructor(_url: string) { super(); sockets.push(this); queueMicrotask(() => this.emit("open")); }
  send(line: string, callback?: (error?: Error) => void): void {
    if (this.throwSend) throw new Error("write failed");
    this.sent.push(line);
    if (JSON.parse(line).type === "hello") queueMicrotask(() => this.emit("message", Buffer.from(JSON.stringify({ type: "challenge", nonce: Buffer.alloc(32).toString("base64") }))));
    if (this.callbackError) { callback?.(new Error("completion failed")); return; }
    if (this.stall) {
      const bytes = Buffer.byteLength(line) + 14;
      this.bufferedAmount += bytes;
      this.maxBuffered = Math.max(this.maxBuffered, this.bufferedAmount);
      this.callbacks.push(() => { this.bufferedAmount -= bytes; callback?.(); });
    } else callback?.();
  }
  terminate(): void { this.readyState = 3; this.emit("close"); }
  close(): void { this.terminate(); }
}
vi.mock("ws", () => ({ default: MockWS }));
const { ManagedRoom } = await import("./managed_transport.js");
const { MANAGED_SEND_LIMIT, RelayClient } = await import("../transport/relay_client.js");
const rooms: InstanceType<typeof ManagedRoom>[] = [];
afterEach(() => { for (const room of rooms) room.close(); rooms.length = 0; sockets.length = 0; });
async function fixture(security?: LaunchSecurity) {
  const child = Object.assign(new EventEmitter(), { connected: true, send: vi.fn(), kill: vi.fn(), exitCode: null, signalCode: null }) as unknown as ChildProcess;
  let epoch = "e", unlocked = true, paired = true, current = true, owned = true;
  const stopChild = vi.fn(async (authorized: () => Promise<boolean>) => { if (!await authorized() || !owned) return false; owned = false; child.emit("exit", 0, null); return true; });
  const authorized = vi.fn(async (e: string) => paired && current && (security ? await security.authorized("owner", e) : unlocked && e === epoch));
  const pairedCheck = vi.fn(async () => paired);
  const room = new ManagedRoom({ agent: { agent_id: "a", name: "assigned", cwd: "/assigned", room_id: "assigned-room", state: "running" }, child, owner: "owner", url: "ws://fixture", keypair: generateEd25519Keypair(),
    currentEpoch: () => security?.epoch ?? epoch,
    ...(security ? { access: (e: string) => security.access("owner", e), launchingHost: { room_id: "actual-root-room", launcher_id: security.launcherId } } : {}), authorized, ownsChild: () => owned, stopChild,
    paired: pairedCheck, current: () => current, hasGrant: e => security ? security.hasGrant("owner", e) : unlocked && e === epoch });
  rooms.push(room); await room.connect(); const ws = sockets.at(-1)!;
  const emit = (message: object) => child.emit("message", { type: "managed_event", epoch, message });
  const meta = (value: object) => child.emit("message", { type: "managed_metadata", epoch, meta: value });
  return { child, room, ws, emit, meta, authorized, pairedCheck, stopChild, expire() { unlocked = false; }, replaceChild() { owned = false; }, lock() { epoch = "locked"; unlocked = false; room.revoke(); }, unlock() { epoch = "unlocked"; unlocked = true; room.revoke(); }, unpair() { paired = false; }, replace() { current = false; } };
}
const settle = () => new Promise<void>(resolve => setImmediate(resolve));

test("managed valid near-limit output on a non-reading WS is byte bounded and overflow terminates only its child", async () => {
  const f = await fixture(); f.ws.stall = true;
  const message: import("../protocol/types.js").ServerMessage = { type: "agent_chunk", in_reply_to: "accepted", delta: "x".repeat(5_900_000) };
  for (let i = 0; i < 12; i++) { f.emit(message); await settle(); }
  expect(f.ws.maxBuffered).toBeLessThanOrEqual(12_000_000);
  expect(MANAGED_SEND_LIMIT).toBe(12_000_000);
  expect(f.ws.readyState).toBe(3);
  expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL");
  const queued = f.ws.sent.length; f.emit(message); await settle(); expect(f.ws.sent).toHaveLength(queued);
  for (const complete of f.ws.callbacks) complete();
  expect(f.child.kill).toHaveBeenCalledTimes(1);
});

test.each(["callback", "throw", "close"])("managed %s send failures clean up room and child without retry", async failure => {
  const f = await fixture();
  if (failure === "callback") f.ws.callbackError = true;
  if (failure === "throw") f.ws.throwSend = true;
  if (failure === "close") f.ws.terminate();
  f.emit({ type: "pong", in_reply_to: "p" }); await settle();
  expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL"); expect(f.ws.readyState).toBe(3);
  f.room.close(); f.emit({ type: "pong", in_reply_to: "p2" }); await settle();
  expect(f.child.kill).toHaveBeenCalledTimes(1);
});

test("all managed error/metadata frames share the byte cap; ordinary send semantics stay unchanged", async () => {
  const f = await fixture(); f.ws.bufferedAmount = MANAGED_SEND_LIMIT - 10;
  f.lock();
  f.ws.emit("message", Buffer.from(JSON.stringify({ peer: "owner", ct: Buffer.from(JSON.stringify({ type: "ping", id: "locked" })).toString("base64") })));
  await settle(); expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL");
  const metadata = await fixture(); metadata.ws.bufferedAmount = MANAGED_SEND_LIMIT - 10;
  metadata.meta({ working: true });
  await expect.poll(() => vi.mocked(metadata.child.kill).mock.calls.length).toBe(1);
  const relay = new RelayClient("ws://ordinary", generateEd25519Keypair()); await relay.connect();
  const ordinary = sockets.at(-1)!; ordinary.bufferedAmount = MANAGED_SEND_LIMIT;
  expect(() => relay.send('{"ordinary":true}')).not.toThrow(); relay.close();
});

test("completion accounting bounds even under-reported bufferedAmount and frees completed writes", async () => {
  const relay = new RelayClient("ws://fixture", generateEd25519Keypair()); await relay.connect();
  const ws = sockets.at(-1)!; ws.stall = true; const fail = vi.fn();
  relay.sendManaged(JSON.stringify({ data: "x".repeat(6_000_000) }), fail);
  ws.bufferedAmount = 0;
  relay.sendManaged(JSON.stringify({ data: "x".repeat(6_000_000) }), fail);
  expect(fail).toHaveBeenCalledTimes(1);
  ws.callbacks[0]!(); ws.bufferedAmount = 0;
  relay.sendManaged(JSON.stringify({ data: "x".repeat(6_000_000) }), fail);
  expect(fail).toHaveBeenCalledTimes(1); relay.terminateManaged();
});

test("real parent proxy coalesces exact metadata, locked updates only working, unlock republishes latest snapshot", async () => {
  const f = await fixture();
  f.meta({ working: false, model: "initial", thinking: "low" });
  const updates = () => f.ws.sent.map(line => JSON.parse(line)).filter(m => m.type === "room_meta_update");
  await expect.poll(() => updates().length).toBe(1);
  expect(updates()[0]).toEqual({ type: "room_meta_update", room_id: "assigned-room", meta: { working: false, model: "initial", thinking: "low" } });
  for (let i = 0; i < 1000; i++) f.meta({ working: true, model: `model-${i}`, thinking: "high" });
  await expect.poll(() => updates().length).toBe(2);
  expect(updates()[1].meta).toEqual({ working: true, model: "model-999", thinking: "high" });
  f.lock(); f.meta({ working: false, model: "locked-sensitive-label", thinking: "max" });
  await expect.poll(() => updates().length).toBe(3);
  expect(updates()[2].meta).toEqual({ working: false });
  f.emit({ type: "agent_chunk", in_reply_to: "accepted", delta: "protected" }); await settle();
  expect(f.ws.sent.some(line => JSON.parse(line).ct)).toBe(false);
  f.unlock(); await expect.poll(() => updates().length).toBe(4);
  expect(updates()[3].meta).toEqual({ working: false, model: "locked-sensitive-label", thinking: "max" });
  f.unpair(); f.meta({ working: true }); await new Promise(r => setTimeout(r, 150)); expect(updates()).toHaveLength(4);
});

test.each(["room_id", "cwd", "owner", "display"])("private metadata rejects arbitrary %s and closes malicious child", async field => {
  const f = await fixture(); f.meta({ working: true, [field]: "attacker" });
  expect(f.child.kill).toHaveBeenCalledExactlyOnceWith("SIGKILL");
});

test("metadata wire fixture matches real frozen Home working consumer (no active-chat dependency)", async () => {
  const f = await fixture(); f.meta({ working: true });
  await expect.poll(() => f.ws.sent.some(line => JSON.parse(line).type === "room_meta_update")).toBe(true);
  const frame = f.ws.sent.map(line => JSON.parse(line)).find(m => m.type === "room_meta_update");
  // Relay merges the patch into room_meta_updated; working remains a bool.
  const push = { type: "room_meta_updated", peer: "owner", room_id: frame.room_id, meta: frame.meta };
  expect(push.meta.working).toBe(true);
  const home = readFileSync(new URL("../../../app/lib/ui/home/viewmodels/home_viewmodel.dart", import.meta.url), "utf8");
  const connection = readFileSync(new URL("../../../app/lib/data/transport/connection_manager.dart", import.meta.url), "utf8");
  expect(home).toContain("_conn.isRoomWorking(epk, roomId)");
  expect(connection).toContain("final nextWorking = working ?? current.working;");
  expect(connection).toContain("if (r.roomId == roomId) return r.working;");
  const codec = readFileSync(new URL("../../../app/lib/protocol/protocol.dart", import.meta.url), "utf8");
  expect(codec).toContain("'room_meta_updated' => () {");
  expect(codec).toContain("working: meta?['working'] as bool?,");
});

test.each(["Lock", "replacement", "unpair", "child exit"])("metadata final pairing lookup cannot disclose labels after %s", async change => {
  const f = await fixture();
  let release!: (paired: boolean) => void, entered!: () => void;
  const parked = new Promise<boolean>(r => { release = r; });
  const waiting = new Promise<void>(r => { entered = r; });
  f.authorized.mockImplementationOnce(async () => {
    f.pairedCheck.mockImplementationOnce(() => { entered(); return parked; });
    return true;
  });
  f.meta({ working: true, model: "pending-sensitive", thinking: "high" });
  await waiting;
  if (change === "Lock") f.lock();
  if (change === "replacement") f.replace();
  if (change === "unpair") f.unpair();
  if (change === "child exit") Object.assign(f.child, { connected: false });
  release(change !== "unpair");
  await new Promise(r => setTimeout(r, 150));
  const updates = f.ws.sent.map(line => JSON.parse(line)).filter(m => m.type === "room_meta_update");
  expect(updates.every(m => Object.keys(m.meta).join() === "working")).toBe(true);
  if (change !== "Lock") expect(updates).toHaveLength(0);
});

test("closing during pending managed completion neither retries nor kills an already disposed child", async () => {
  const f = await fixture(); f.ws.stall = true;
  f.emit({ type: "pong", in_reply_to: "pending" }); await settle();
  expect(f.ws.callbacks).toHaveLength(1);
  f.room.close(); f.ws.callbacks[0]!(); f.ws.callbacks[0]!();
  expect(f.child.kill).not.toHaveBeenCalled();
  expect(f.ws.readyState).toBe(3);
});


const controlSend = (f: Awaited<ReturnType<typeof fixture>>, message: object, peer = "owner") => f.ws.emit("message", Buffer.from(JSON.stringify({ peer, ct: Buffer.from(JSON.stringify(message)).toString("base64") })));
const controlReplies = (f: Awaited<ReturnType<typeof fixture>>) => f.ws.sent.map(line => JSON.parse(line)).filter(m => m.ct).map(m => JSON.parse(Buffer.from(m.ct, "base64").toString()));
const controlStatus = async (f: Awaited<ReturnType<typeof fixture>>) => { const count = controlReplies(f).length; controlSend(f, { type: "session_control_status", id: "status", room_id: "assigned-room" }); await expect.poll(() => controlReplies(f).length).toBeGreaterThan(count); return controlReplies(f).at(-1); };
test("session control managed status while locked never returns a token", async () => {
  const f = await fixture(); f.lock();
  expect(await controlStatus(f)).toEqual({ type: "session_control_status_result", in_reply_to: "status", room_id: "assigned-room", can_stop: false, reason: "Unlock the launching host first." });
  expect(f.stopChild).not.toHaveBeenCalled(); expect(f.child.send).toHaveBeenCalledTimes(2); // init + revoke only
});
test("session control managed exact owned child stops once and reports actual exit", async () => {
  const f = await fixture(); const status = await controlStatus(f); expect(status.can_stop).toBe(true);
  controlSend(f, { type: "session_stop", id: "stop", room_id: "assigned-room", token: status.token }); await settle();
  expect(f.stopChild).toHaveBeenCalledTimes(1);
  expect(controlReplies(f).at(-1)).toMatchObject({ type: "session_stop_result", state: "stopped", in_reply_to: "stop" });
  controlSend(f, { type: "session_stop", id: "replay", room_id: "assigned-room", token: status.token }); await settle(); expect(f.stopChild).toHaveBeenCalledTimes(1);
  expect(f.child.send).toHaveBeenCalledTimes(1); // new controls are never forwarded into the child/model
  expect(f.ws.readyState).toBe(3);
  expect(f.child.listenerCount("exit")).toBe(0);
  expect(f.child.listenerCount("message")).toBe(0);
});
test.each(["lock", "unpair", "replace", "replaceChild", "exit", "foreign-room", "foreign-owner"])("session control managed %s invalidates captured child capability", async action => {
  const f = await fixture(); const status = await controlStatus(f);
  if (action === "lock") f.lock();
  if (action === "unpair") f.unpair();
  if (action === "replace") f.replace();
  if (action === "replaceChild") f.replaceChild();
  if (action === "exit") f.child.emit("exit", 0, null);
  controlSend(f, { type: "session_stop", id: "stop", room_id: action === "foreign-room" ? "other" : "assigned-room", token: status.token }, action === "foreign-owner" ? "other" : "owner"); await settle();
  expect(f.stopChild).not.toHaveBeenCalled();
});
test("session control managed late grant lookup cannot outlive revocation", async () => {
  const f = await fixture(); const status = await controlStatus(f);
  let release!: (ok: boolean) => void;
  f.authorized.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
  controlSend(f, { type: "session_stop", id: "stop", room_id: "assigned-room", token: status.token });
  await settle(); f.lock(); release(true); await settle(); expect(f.stopChild).not.toHaveBeenCalled();
});

test("session control managed expires authority during exit and suppresses stopped reply", async () => {
  const f = await fixture(); const status = await controlStatus(f);
  const original = f.stopChild.getMockImplementation()!;
  f.stopChild.mockImplementationOnce(async authorized => { const stopped = await original(authorized); f.expire(); return stopped; });
  controlSend(f, { type: "session_stop", id: "stop", room_id: "assigned-room", token: status.token }); await settle();
  expect(f.stopChild).toHaveBeenCalledTimes(1);
  expect(controlReplies(f).some(m => m.type === "session_stop_result")).toBe(false);
  expect(f.ws.readyState).toBe(3);
  expect(f.child.listenerCount("exit")).toBe(0);
  expect(f.child.listenerCount("message")).toBe(0);
});
test("session control managed rejects malformed known fields with correlated error", async () => {
  const f = await fixture(); controlSend(f, { type: "session_control_status", id: "bad", room_id: "assigned-room", pid: 123 }); await settle();
  expect(controlReplies(f).at(-1)).toMatchObject({ type: "error", in_reply_to: "bad" });
  expect(f.stopChild).not.toHaveBeenCalled();
});


test("correct root unlock → child capability → actual grant expiry → re-unlock; other launcher never grants child access", async () => {
  const dir = await mkdtemp(join(tmpdir(), "managed-access-"));
  let now = Date.now();
  try {
    await setupLaunchPin("654321", dir);
    const root = new LaunchSecurity("actual-root-launcher", dir, () => now);
    const other = new LaunchSecurity("other-launcher", dir, () => now);
    const f = await fixture(root);
    await other.unlock("owner", "other-unlock", other.launcherId, other.epoch, "654321", async () => true);
    let status = await controlStatus(f);
    expect(status).toMatchObject({ can_stop: false, access: { state: "locked", expires_at: null }, launching_host: { room_id: "actual-root-room", launcher_id: root.launcherId } });
    expect(status.token).toBeUndefined();
    await root.unlock("owner", "correct", root.launcherId, root.epoch, "654321", async () => true);
    status = await controlStatus(f);
    expect(status.can_stop).toBe(true);
    expect(status.access).toEqual({ state: "unlocked", expires_at: now + 300000 });
    const oldToken = status.token;
    now += 300001;
    status = await controlStatus(f);
    expect(status).toMatchObject({ can_stop: false, access: { state: "expired", expires_at: now - 1 } });
    expect(status.token).toBeUndefined();
    await root.unlock("owner", "correct-again", root.launcherId, root.epoch, "654321", async () => true);
    status = await controlStatus(f);
    expect(status.can_stop).toBe(true); expect(status.token).not.toBe(oldToken);
    root.lock();
    status = await controlStatus(f);
    expect(status.access).toEqual({ state: "locked", expires_at: null }); expect(status.token).toBeUndefined();
    controlSend(f, { type: "session_control_status", id: "foreign", room_id: "assigned-room" }, "not-owner");
    await settle(); expect(controlReplies(f).at(-1).in_reply_to).not.toBe("foreign");
    expect(f.stopChild).not.toHaveBeenCalled();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test.each(["lock", "replace", "unpair", "exit"])("access/origin suppressed after final pairing await races %s", async change => {
  const dir = await mkdtemp(join(tmpdir(), "managed-access-race-"));
  try {
    const security = new LaunchSecurity("root", dir);
    const f = await fixture(security);
    let release!: (ok: boolean) => void;
    f.pairedCheck.mockImplementationOnce(() => new Promise(resolve => { release = resolve; }));
    controlSend(f, { type: "session_control_status", id: "race", room_id: "assigned-room" });
    await settle();
    if (change === "lock") security.lock();
    if (change === "replace") f.replace();
    if (change === "unpair") f.unpair();
    if (change === "exit") f.child.emit("exit", 0, null);
    release(change !== "unpair"); await settle();
    expect(controlReplies(f).filter(r => r.type === "session_control_status_result")).toHaveLength(0);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test.each(["hello", "auth"])("managed publication checks startup authority before %s without publishing after revocation", async phase => {
  let granted = true;
  const relay = new RelayClient("ws://fixture", generateEd25519Keypair());
  let checks = 0;
  await expect(relay.connect({ managed: true, current: () => granted, admitted: async () => {
    checks++;
    if (checks === (phase === "hello" ? 1 : 2)) granted = false;
    return granted;
  } })).rejects.toThrow();
  const sent = sockets.at(-1)!.sent.map(line => JSON.parse(line));
  expect(sent.some(m => m.type === "auth")).toBe(false);
  expect(sent.some(m => m.type === "hello")).toBe(phase === "auth");
  relay.terminateManaged();
});
