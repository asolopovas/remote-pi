import { beforeEach, afterEach, describe, expect, test, vi } from "vitest";
import { RoomDisplayEndpoint } from "./room_display_endpoint.js";
import { PlainPeerChannel } from "./peer_channel.js";
import { roomIdFor } from "../rooms.js";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import type { RelayClient, RoomDisplay } from "./relay_client.js";

const OWNER = Buffer.alloc(32, 1).toString("base64");
const PC = Buffer.alloc(32, 2).toString("base64");
const NATIVE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const EPOCH = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const nonce = (n = 1) => `cccccccc-cccc-4ccc-8ccc-${n.toString(16).padStart(12, "0")}`;
const request = (room = "routing-A", n = 1) => ({ type: "room_display_request", id: nonce(n), room_id: room });
const encode = (inner: unknown) => Buffer.from(JSON.stringify(inner)).toString("base64");
const envelope = (inner: unknown, peer = OWNER, room = "phone-main") => ({ peer, room, ct: encode(inner) });
const flush = async () => { for (let n = 0; n < 10; n++) await Promise.resolve(); };
function harness(roomId = "routing-A") {
  let current = true;
  let display: RoomDisplay | null = { native_session_id: NATIVE, epoch: EPOCH, revision: 1, name: "Desktop A" };
  const known = vi.fn(async (peer: string) => peer === OWNER);
  const send = vi.fn();
  const endpoint = new RoomDisplayEndpoint({
    findKnownPeer: known,
    captureScope: () => ({ roomId, isCurrent: () => current, snapshot: () => display }),
    send,
  });
  const consume = (inner: unknown = request(roomId), peer = OWNER, senderRoom = "phone-main", ct?: string) => {
    const outer = envelope(inner, peer, senderRoom);
    if (ct !== undefined) outer.ct = ct;
    return endpoint.consume(outer, inner, Buffer.byteLength(JSON.stringify(outer)));
  };
  return { endpoint, known, send, consume, retire: () => { current = false; }, setDisplay: (value: RoomDisplay | null) => { display = value; } };
}
beforeEach(() => vi.useFakeTimers());
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe("RoomDisplayEndpoint dedicated paired-owner metadata", () => {
  test("paired nonactive exact-room request answers only requester registered room, never a chat channel", async () => {
    const h = harness();
    expect(h.consume()).toBe(true);
    await flush();
    expect(h.known).toHaveBeenCalledOnce();
    const outer = JSON.parse(h.send.mock.calls[0][0]);
    expect(outer).toEqual({ peer: OWNER, room: "phone-main", ct: expect.any(String) });
    expect(JSON.parse(Buffer.from(outer.ct, "base64").toString())).toEqual({
      type: "room_display_snapshot", in_reply_to: nonce(), room_id: "routing-A",
      display: { native_session_id: NATIVE, epoch: EPOCH, revision: 1, name: "Desktop A" },
    });
  });

  test("unpaired, wrong room, malformed, extra fields, oversized and noncanonical envelopes are consumed without a response", async () => {
    const invalid = [
      { type: "room_display_request", id: "not-uuid", room_id: "routing-A" },
      { ...request(), room_id: "other-room" },
      { ...request(), extra: "never echo" },
      { ...request(), id: "x".repeat(5_000) },
      { ...request(), room_id: { arbitrary: true } },
    ];
    for (const inner of invalid) { const h = harness(); expect(h.consume(inner)).toBe(true); await flush(); expect(h.send).not.toHaveBeenCalled(); expect(h.known).not.toHaveBeenCalled(); }
    for (const [peer, room, ct] of [[PC, "main", undefined], [OWNER.slice(0, -1), "main", undefined], [OWNER, "", undefined], [OWNER, "main", encode(request()) + "!"]] as const) {
      const h = harness(); h.consume(request(), peer, room, ct); await flush(); expect(h.send).not.toHaveBeenCalled();
    }
    const h = harness();
    expect(h.consume({ type: "room_display_snapshot", display: "untrusted" })).toBe(true);
    expect(h.consume({ type: "ping", id: "normal" })).toBe(false);
    expect(h.known).not.toHaveBeenCalled();
  });

  test("exact scope retirement, dispose, lookup failure and expiration cannot publish awaited results", async () => {
    for (const action of ["retire", "dispose", "expire", "reject"] as const) {
      const h = harness(); let resolve!: (known: boolean) => void; let reject!: () => void;
      h.known.mockImplementation(() => new Promise<boolean>((yes, no) => { resolve = yes; reject = () => no(new Error("storage")); }));
      h.consume();
      if (action === "retire") h.retire();
      if (action === "dispose") h.endpoint.dispose();
      if (action === "expire") await vi.advanceTimersByTimeAsync(3_001);
      if (action === "reject") reject(); else resolve(true);
      await flush(); expect(h.send).not.toHaveBeenCalled();
    }
  });

  test("bounded rate, nonce replay, lanes and concurrency, including hung lookups", async () => {
    const h = harness(); h.consume(); h.consume(); await flush(); expect(h.send).toHaveBeenCalledOnce();
    await vi.advanceTimersByTimeAsync(1_001); h.consume(); await flush(); expect(h.send).toHaveBeenCalledOnce();
    h.consume(request("routing-A", 2)); await flush(); expect(h.send).toHaveBeenCalledTimes(2);
    const hung = harness(); hung.known.mockImplementation(() => new Promise(() => {}));
    for (let n = 1; n <= 100; n++) hung.consume(request("routing-A", n), OWNER, `phone-${n}`);
    expect(hung.known).toHaveBeenCalledTimes(4);
    await vi.advanceTimersByTimeAsync(20_000);
    for (let n = 101; n <= 200; n++) hung.consume(request("routing-A", n), OWNER, `phone-${n}`);
    expect(hung.known).toHaveBeenCalledTimes(4);
    hung.endpoint.dispose();
  });

  test("global rate and retained nonce ledger remain bounded until expiry", async () => {
    const h = harness();
    for (let tick = 0; tick < 8; tick++) {
      for (let n = 0; n < 9; n++) { h.consume(request("routing-A", tick * 9 + n + 1), OWNER, `phone-${n}`); await flush(); }
      expect(h.send).toHaveBeenCalledTimes((tick + 1) * 8);
      await vi.advanceTimersByTimeAsync(1_001);
    }
    h.consume(request("routing-A", 100), OWNER, "phone-new"); await flush(); expect(h.send).toHaveBeenCalledTimes(64);
    await vi.advanceTimersByTimeAsync(2_000);
    h.consume(request("routing-A", 101), OWNER, "phone-new"); await flush(); expect(h.send).toHaveBeenCalledTimes(65);
    h.endpoint.dispose(); h.consume(request("routing-A", 102), OWNER, "another"); await flush(); expect(h.send).toHaveBeenCalledTimes(65);
  });

  test("readable cross-component fixture has exact base64 bodies and authenticated response scopes", () => {
    const fixture = JSON.parse(readFileSync(new URL("../../test/fixtures/81-room-display-endpoint.json", import.meta.url), "utf8"));
    for (const frame of fixture.frames) {
      expect(JSON.parse(Buffer.from(frame.wire.ct, "base64").toString())).toEqual(frame.inner);
      if (frame.inner.type === "room_display_snapshot") { expect(frame.wire.peer).toBe(fixture.pc_peer); expect(frame.wire.room).toBe(frame.inner.room_id); }
    }
    expect(fixture.frames.map((frame: { label: string }) => frame.label)).toEqual(["request-delivered-to-extension", "verified-name", "verified-reset", "unavailable"]);
  });

  test("rename, null reset and unavailable snapshots preserve native/epoch/revision distinction", async () => {
    const h = harness();
    const displays: (RoomDisplay | null)[] = [
      { native_session_id: NATIVE, epoch: EPOCH, revision: 2, name: "Renamed" },
      { native_session_id: NATIVE, epoch: EPOCH, revision: 3, name: null }, null,
    ];
    for (let n = 0; n < displays.length; n++) {
      h.setDisplay(displays[n]); h.consume(request("routing-A", n + 1)); await flush(); await vi.advanceTimersByTimeAsync(1_001);
    }
    expect(h.send.mock.calls.map(([line]) => JSON.parse(Buffer.from(JSON.parse(line).ct, "base64").toString()).display)).toEqual(displays);
  });

  test("faithful legacy ct forwarding overwrites sender identity+registered room, distinct duplicate-cwd routing", async () => {
    // pre-feature relay peer.rs envelope path: route by destination peer/room;
    // rewrite only peer and room with authenticated socket registration, ct opaque.
    const legacyForward = (line: string, peer: string, registeredRoom: string) => {
      const outbound = JSON.parse(line);
      return JSON.stringify({ peer, room: registeredRoom, ct: outbound.ct });
    };
    const rooms = [roomIdFor("/duplicate", "agent-A"), roomIdFor("/duplicate", "agent-B")];
    expect(rooms[0]).not.toBe(rooms[1]);
    const endpoints = rooms.map(room => harness(room));
    for (let n = 0; n < 2; n++) {
      const target = rooms[n];
      const client = JSON.stringify({ peer: PC, room: target, ct: encode(request(target, n + 1)) });
      const destination = JSON.parse(client);
      // Legacy registry selects the exact destination room before the sender
      // rewrite. No control forwarding or broadcast to a different Pi room.
      expect(destination.peer).toBe(PC);
      const routed = endpoints[rooms.indexOf(destination.room)];
      const incoming = JSON.parse(legacyForward(client, OWNER, "phone-main"));
      routed.endpoint.consume(incoming, JSON.parse(Buffer.from(incoming.ct, "base64").toString()), Buffer.byteLength(JSON.stringify(incoming)));
    }
    await flush();
    for (let n = 0; n < 2; n++) {
      const h = endpoints[n]; expect(h.send).toHaveBeenCalledOnce();
      const outbound = JSON.parse(h.send.mock.calls[0][0]);
      expect(outbound.peer).toBe(OWNER); expect(outbound.room).toBe("phone-main");
      const response = JSON.parse(legacyForward(h.send.mock.calls[0][0], PC, rooms[n]));
      const inner = JSON.parse(Buffer.from(response.ct, "base64").toString());
      expect(response.peer).toBe(PC); expect(response.room).toBe(rooms[n]); expect(inner.room_id).toBe(response.room); expect(inner.in_reply_to).toBe(nonce(n + 1));
    }
  });

  test("active PlainPeerChannel excludes both metadata types; dedicated route responds exactly once", async () => {
    const relay = Object.assign(new EventEmitter(), { send: vi.fn() }); const chat = vi.fn();
    const channel = new PlainPeerChannel(relay as unknown as RelayClient, OWNER, "routing-A", chat);
    const h = harness();
    relay.on("message", (line: string) => { const outer = JSON.parse(line); h.endpoint.consume(outer, JSON.parse(Buffer.from(outer.ct, "base64").toString()), Buffer.byteLength(line)); });
    relay.emit("message", JSON.stringify(envelope(request())));
    relay.emit("message", JSON.stringify(envelope({ type: "room_display_snapshot" })));
    await flush(); expect(chat).not.toHaveBeenCalled(); expect(h.send).toHaveBeenCalledOnce(); expect(relay.send).not.toHaveBeenCalled();
    channel.detach(); h.endpoint.dispose();
  });
});
