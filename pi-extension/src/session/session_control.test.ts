import { expect, test, vi } from "vitest";
import { SessionControl, type SessionControlTarget } from "./session_control.js";
import type { SessionControlResult } from "../protocol/types.js";
function fixture(completion: "requested" | "stopped" = "requested") {
  const control = new SessionControl();
  let live = true, paired = true, eligible = true;
  const replies: SessionControlResult[] = [];
  const stop = vi.fn();
  const target: SessionControlTarget = { current: () => live, authorized: async () => paired, eligible: () => eligible, reason: "Exact process", completion, stop };
  const reply = (r: SessionControlResult) => { replies.push(r); };
  const status = () => control.handle("owner", { type: "session_control_status", id: "status", room_id: "room" }, target, reply);
  const token = () => (replies.at(-1) as { token: string }).token;
  const confirm = (value = token(), owner = "owner", room_id = "room") => control.handle(owner, { type: "session_stop", id: "stop", room_id, token: value }, target, reply);
  return { control, target, replies, reply, stop, status, token, confirm, replace() { live = false; }, revoke() { paired = false; }, lock() { eligible = false; } };
}
test("root ack precedes effect, confirmation is one-use without replay", async () => {
  const f = fixture(); await f.status(); const token = f.token();
  f.stop.mockImplementation(() => expect(f.replies.at(-1)).toMatchObject({ state: "requested" }));
  await f.confirm(token); await expect(f.confirm(token)).rejects.toThrow(); expect(f.stop).toHaveBeenCalledTimes(1);
});
test.each(["replace", "revoke", "lock"] as const)("%s invalidates confirmation", async action => {
  const f = fixture(); await f.status(); const token = f.token(); f[action]();
  await expect(f.confirm(token)).rejects.toThrow(); expect(f.stop).not.toHaveBeenCalled();
});
test.each(["owner", "room"])("token is exact %s scoped", async field => {
  const f = fixture(); await f.status();
  await expect(f.confirm(f.token(), field === "owner" ? "other" : "owner", field === "room" ? "other" : "room")).rejects.toThrow(); expect(f.stop).not.toHaveBeenCalled();
});
test("expiry and bounded memory deny without tokens", async () => {
  vi.useFakeTimers(); try {
    const f = fixture(); await f.status(); const token = f.token(); await vi.advanceTimersByTimeAsync(30_000);
    await expect(f.confirm(token)).rejects.toThrow();
    for (let i = 0; i < 257; i++) await f.status();
    expect(f.replies.at(-1)).toMatchObject({ can_stop: false }); expect(f.token()).toBeUndefined();
  } finally { vi.useRealTimers(); }
});
test("late authorization and synchronous post-reply replacement cannot trigger effects", async () => {
  const f = fixture(); await f.status(); const token = f.token();
  f.target.authorized = async () => { f.replace(); return true; };
  await expect(f.confirm(token)).rejects.toThrow(); expect(f.stop).not.toHaveBeenCalled();
  const g = fixture(); await g.status();
  await g.control.handle("owner", { type: "session_stop", id: "stop", room_id: "room", token: g.token() }, g.target, () => g.replace());
  expect(g.stop).not.toHaveBeenCalled();
});
test("managed stop replies only after confirmed exit and post-stop authorization", async () => {
  const f = fixture("stopped");
  let finish!: (stopped: boolean) => void;
  f.target.stop = () => new Promise<boolean>(resolve => { finish = resolve; });
  await f.status(); const pending = f.confirm(); await vi.waitFor(() => expect(finish).toBeTypeOf("function"));
  expect(f.replies).toHaveLength(1); finish(true); await pending; expect(f.replies.at(-1)).toMatchObject({ state: "stopped" });
});
