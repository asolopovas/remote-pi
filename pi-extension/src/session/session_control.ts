import { randomBytes } from "node:crypto";
import type { SessionControlRequest, SessionControlResult } from "../protocol/types.js";

/** A capability captures one exact incarnation, not a dynamically resolved target. */
export interface SessionControlTarget {
  current(): boolean;
  authorized(forStop: boolean): Promise<boolean>;
  eligible(): boolean;
  reason: string;
  readonly completion: "requested" | "stopped";
  stop(): Promise<boolean> | void;
  finishStop?(): void;
}
interface Capability { owner: string; room: string; target: SessionControlTarget; expires: number }
export class SessionControl {
  private readonly tokens = new Map<string, Capability>();
  async handle(owner: string, request: SessionControlRequest, target: SessionControlTarget,
    reply: (result: SessionControlResult) => void): Promise<void> {
    for (const [token, cap] of this.tokens) if (cap.expires <= Date.now() || !cap.target.current()) this.tokens.delete(token);
    if (!await target.authorized(request.type === "session_stop") || !target.current()) throw new Error("Session authority changed");
    if (request.type === "session_control_status") {
      if (!target.eligible() || this.tokens.size >= 256) {
        reply({ type: "session_control_status_result", in_reply_to: request.id, room_id: request.room_id, can_stop: false, reason: this.tokens.size >= 256 ? "Session controls are busy; try again." : target.reason });
        return;
      }
      const token = randomBytes(32).toString("hex");
      this.tokens.set(token, { owner, room: request.room_id, target, expires: Date.now() + 30_000 });
      reply({ type: "session_control_status_result", in_reply_to: request.id, room_id: request.room_id, can_stop: true, token, reason: target.reason });
      return;
    }
    const cap = this.tokens.get(request.token);
    // Spend before any further await. Lost acknowledgements are not replayable.
    this.tokens.delete(request.token);
    if (!cap || cap.owner !== owner || cap.room !== request.room_id || cap.expires <= Date.now() || !cap.target.current()) throw new Error("Confirmation expired; refresh session controls");
    if (!await cap.target.authorized(true) || !cap.target.current() || !cap.target.eligible() || cap.expires <= Date.now()) throw new Error("Session authority changed");
    // Root SDK shutdown is synchronous: acknowledge before invoking it, and
    // guard again after reply (which may synchronously detach the channel).
    if (cap.target.completion === "requested") {
      reply({ type: "session_stop_result", in_reply_to: request.id, room_id: request.room_id, state: "requested" });
      if (cap.target.current() && cap.target.eligible()) cap.target.stop();
    } else {
      try {
        const stopped = await cap.target.stop();
        if (!await cap.target.authorized(true) || !cap.target.current()) return;
        if (!stopped) throw new Error("Session stop not confirmed");
        reply({ type: "session_stop_result", in_reply_to: request.id, room_id: request.room_id, state: "stopped" });
      } finally {
        cap.target.finishStop?.();
      }
    }
  }
}
