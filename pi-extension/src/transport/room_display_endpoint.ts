import type { RoomDisplaySnapshot } from "../protocol/types.js";
import type { RoomDisplay } from "./relay_client.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_LINE_BYTES = 4_096;
const MAX_INNER_BYTES = 1_024;
const MAX_LANES = 64;
const MAX_NONCES = 64;
const RETENTION_MS = 10_000;
const LOOKUP_DEADLINE_MS = 3_000;
const LANE_INTERVAL_MS = 1_000;
const MAX_PER_SECOND = 8;
const MAX_PENDING = 4;

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function room(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= 256 &&
    !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value);
}
function canonicalPeer(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9+/]{43}=$/.test(value) &&
    Buffer.from(value, "base64").toString("base64") === value;
}

/** Reserved display messages never belong to the normal chat/reconnect router. */
export function isRoomDisplayMessage(value: unknown): boolean {
  return record(value) && (value.type === "room_display_request" || value.type === "room_display_snapshot");
}

export interface RoomDisplayScope {
  roomId: string;
  isCurrent(): boolean;
  snapshot(): RoomDisplay | null;
}
interface RoomDisplayEndpointOptions {
  captureScope(): RoomDisplayScope | null;
  findKnownPeer(peer: string): Promise<boolean>;
  send(line: string): void;
}

/** Request-only endpoint on the existing opaque envelope path. No channels,
 * SDK work, history, queues, watchers, retries or body/key diagnostics here.
 */
export class RoomDisplayEndpoint {
  private disposed = false;
  private pending = 0;
  private readonly lanes = new Map<string, number>();
  private readonly nonces = new Map<string, number>();
  private rateWindow = 0;
  private rateCount = 0;

  constructor(private readonly options: RoomDisplayEndpointOptions) {}

  /** Synchronously reserves both metadata types, even malformed requests, before
   * active-owner/reconnect dispatch. Only a validated request can start a lookup.
   */
  consume(outer: unknown, inner: unknown, lineBytes: number): boolean {
    if (!isRoomDisplayMessage(inner)) return false;
    if (this.disposed || !record(inner) || inner.type !== "room_display_request" ||
        !record(outer) || !Number.isSafeInteger(lineBytes) || lineBytes < 0 || lineBytes > MAX_LINE_BYTES ||
        !canonicalPeer(outer.peer) || !room(outer.room) || typeof outer.ct !== "string" ||
        outer.ct.length > Math.ceil(MAX_INNER_BYTES / 3) * 4 ||
        !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(outer.ct) ||
        Buffer.from(outer.ct, "base64").toString("base64") !== outer.ct ||
        Buffer.from(outer.ct, "base64").length > MAX_INNER_BYTES ||
        Object.keys(inner).length !== 3 || typeof inner.id !== "string" || !UUID.test(inner.id) ||
        !room(inner.room_id)) return true;

    const scope = this.options.captureScope();
    if (!scope || scope.roomId !== inner.room_id || !scope.isCurrent()) return true;
    const now = Date.now();
    for (const [key, at] of this.lanes) if (now - at >= RETENTION_MS) this.lanes.delete(key);
    for (const [key, at] of this.nonces) if (now - at >= RETENTION_MS) this.nonces.delete(key);
    const lane = `${outer.peer}:${outer.room}`;
    const nonce = `${lane}:${inner.id.toLowerCase()}`;
    const last = this.lanes.get(lane);
    if (this.pending >= MAX_PENDING || this.nonces.has(nonce) ||
        (last !== undefined && now - last < LANE_INTERVAL_MS) ||
        (!this.lanes.has(lane) && this.lanes.size >= MAX_LANES) || this.nonces.size >= MAX_NONCES) return true;
    if (now - this.rateWindow >= 1_000) { this.rateWindow = now; this.rateCount = 0; }
    if (this.rateCount >= MAX_PER_SECOND) return true;
    this.rateCount += 1;
    this.lanes.set(lane, now);
    this.nonces.set(nonce, now);
    this.pending += 1;
    void this.respond(outer.peer, outer.room, inner.id, scope, now);
    return true;
  }

  dispose(): void {
    this.disposed = true;
    this.lanes.clear();
    this.nonces.clear();
  }

  private async respond(peer: string, senderRoom: string, id: string, scope: RoomDisplayScope, started: number): Promise<void> {
    const current = () => !this.disposed && scope.isCurrent() && Date.now() - started <= LOOKUP_DEADLINE_MS;
    try {
      if (!current()) return;
      const known = await this.options.findKnownPeer(peer);
      if (!known || !current()) return;
      const reply: RoomDisplaySnapshot = {
        type: "room_display_snapshot", in_reply_to: id, room_id: scope.roomId, display: scope.snapshot(),
      };
      if (!current()) return;
      // Destination is the requester's registered room, NOT the request's Pi
      // room_id. Relay overwrites the response's peer/room with this Pi socket's
      // authenticated identity/registered room before delivering it to the App.
      this.options.send(JSON.stringify({ peer, room: senderRoom, ct: Buffer.from(JSON.stringify(reply)).toString("base64") }));
    } catch { /* unavailable pairing storage / transport: drop, never echo */ }
    finally { this.pending -= 1; }
    // Hung lookups retain their slot: releasing on timeout would permit an
    // unbounded backlog of unresolved storage operations. No timeout retry.
  }
}
