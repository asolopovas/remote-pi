import { expect, test } from "vitest";
import { decodeSessionControlRequest, decodeServer, encodeClient } from "./codec.js";
import type { SessionControlRequest, SessionControlResult } from "./types.js";

test("session control frozen opaque-envelope fixtures and strict fields", () => {
  const requests: SessionControlRequest[] = [
    { type: "session_control_status", id: "status", room_id: "exact-room" },
    { type: "session_stop", id: "stop", room_id: "exact-room", token: "confirmation" },
  ];
  const results: SessionControlResult[] = [
    { type: "session_control_status_result", in_reply_to: "status", room_id: "exact-room", can_stop: true, token: "confirmation" },
    { type: "session_control_status_result", in_reply_to: "status", room_id: "exact-room", can_stop: false, reason: "Unlock the launching host first." },
    { type: "session_stop_result", in_reply_to: "stop", room_id: "exact-room", state: "requested" },
    { type: "session_stop_result", in_reply_to: "stop", room_id: "exact-room", state: "stopped" },
  ];
  for (const request of requests) {
    const envelope = { peer: "authenticated-owner", ct: Buffer.from(encodeClient(request).trim()).toString("base64") };
    expect(decodeSessionControlRequest(JSON.parse(Buffer.from(envelope.ct, "base64").toString()))).toEqual(request);
    for (const field of ["pid", "env", "command", "path", "owner", "agent_id"]) expect(() => decodeSessionControlRequest({ ...request, [field]: "untrusted" })).toThrow();
    for (const field of ["id", "room_id", ...(request.type === "session_stop" ? ["token"] : [])]) {
      for (const value of ["", "x".repeat(129), "bad\n", "bad\u0080", 1]) expect(() => decodeSessionControlRequest({ ...request, [field]: value })).toThrow();
    }
  }
  for (const result of results) {
    expect(decodeServer(JSON.stringify(result))).toEqual(result);
    expect(() => decodeServer(JSON.stringify({ ...result, pid: 123 }))).toThrow();
  }
  expect(() => decodeServer(JSON.stringify({ ...results[1], token: "must-not-leak" }))).toThrow();
  expect(() => decodeServer(JSON.stringify({ ...results[0], token: undefined }))).toThrow();
});


test("optional access/origin strict snapshots retain legacy compatibility", () => {
  const base = { type: "session_control_status_result", in_reply_to: "q", room_id: "child", can_stop: false };
  for (const state of ["unlocked", "locked", "expired", "unavailable"]) {
    const result = { ...base, access: { state, expires_at: ["unlocked", "expired"].includes(state) ? 123 : null }, launching_host: { room_id: "actual-root", launcher_id: "actual-launcher" } };
    expect(decodeServer(JSON.stringify(result))).toEqual(result);
  }
  for (const access of [null, {}, { state: "other", expires_at: null }, { state: "locked", expires_at: 1 }, { state: "unlocked", expires_at: null }, { state: "expired", expires_at: -1 }, { state: "expired", expires_at: 1.5 }, { state: "locked", expires_at: null, owner: "foreign" }]) expect(() => decodeServer(JSON.stringify({ ...base, access }))).toThrow();
  for (const launching_host of [null, {}, { room_id: "", launcher_id: "l" }, { room_id: "r", launcher_id: "l", cwd: "/guess" }]) expect(() => decodeServer(JSON.stringify({ ...base, launching_host }))).toThrow();
  expect(() => decodeServer(JSON.stringify({ ...base, can_stop: true, token: "t", access: { state: "expired", expires_at: 123 } }))).toThrow();
});
