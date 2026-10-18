import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { ed25519Sign } from "../pairing/crypto.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import type { ThinkingLevel } from "../protocol/types.js";

const AUTH_TIMEOUT_MS = 5_000;
/** Managed-only cap, including UTF8/base64 JSON and worst-case WS framing. */
export const MANAGED_SEND_LIMIT = 12_000_000;

/**
 * Liveness watchdog. The relay sends a WS Ping every ~25s (relay `peer.rs`),
 * so a healthy connection sees inbound frames at least that often. If NOTHING
 * arrives for this long the socket is silently dead — NAT/router idle drop,
 * laptop sleep, or the relay/Cloudflare reaping the connection WITHOUT a clean
 * close frame. That half-open case never fires `close`, so reconnect never
 * triggers and a background daemon sits "online" but dead after a few idle
 * hours. We force-close on timeout so `close` drives the caller's reconnect.
 */
const LIVENESS_TIMEOUT_MS = 70_000;  // ~2.8 missed relay pings → confidently dead
const LIVENESS_CHECK_MS = 20_000;

/** Relay control messages (sent/received during auth). */
interface HelloMsg {
  type: "hello";
  pubkey: string;
  room_id?: string;
  room_meta?: RoomMeta;
}
interface ChallengeMsg { type: "challenge"; nonce: string }
interface AuthMsg { type: "auth"; sig: string }

/** Optional whole-object display metadata; never a routing/history identity. */
export interface RoomDisplay {
  native_session_id: string;
  epoch: string;
  revision: number;
  name: string | null;
}

export interface RoomMeta {
  name: string;
  cwd: string;
  /** Friendly model name (e.g. "claude-sonnet-4.5"). Optional — pi-ext sends
   *  when `ExtensionContext.model` is available; relay/app tolerate absence. */
  model?: string;
  thinking?: ThinkingLevel;
  working?: boolean;
  display?: RoomDisplay;
}

/** Control frame sent to relay (not routed to app peer). */
export interface RoomMetaUpdateFrame {
  type: "room_meta_update";
  room_id: string;
  meta: Pick<RoomMeta, "model" | "thinking" | "working" | "display">;
}

export interface ConnectOptions {
  roomId?: string;
  roomMeta?: RoomMeta;
  /** Private parent-owned managed room: bound hello/auth as well as output. */
  managed?: true;
  /** Managed startup authority, rechecked before hello and signed auth. */
  admitted?: () => Promise<boolean>;
  current?: () => boolean;
}

/** Relay rejected hello because another peer already holds (pubkey, room_id). */
export class RoomAlreadyOpenError extends Error {
  constructor(public readonly roomId: string | undefined) {
    super(
      roomId
        ? `relay rejected hello: room ${roomId} already open for this peer`
        : "relay rejected hello: peer already connected",
    );
    this.name = "RoomAlreadyOpenError";
  }
}

export interface RelayClientEvents {
  /** A single JSONL line delivered by the relay (outer envelope). */
  message: [line: string];
  close: [];
  error: [err: Error];
}

/**
 * Thin WebSocket client for the Remote Pi relay.
 *
 * Lifecycle:
 *   const relay = new RelayClient(url, ed25519Keypair)
 *   await relay.connect()          // opens WS + runs Ed25519 challenge-response
 *   relay.on("message", line => …) // outer envelopes: { peer, ct }
 *   relay.send(jsonLine)           // write to relay
 *   relay.close()
 *
 * Auth sequence (pairing.md §Challenge-response):
 *   → { type:"hello",     pubkey: "<Ed25519 pubkey base64>" }
 *   ← { type:"challenge", nonce:  "<32 bytes base64>" }
 *   → { type:"auth",      sig:    "<Ed25519 sig base64>" }
 */
export class RelayClient extends EventEmitter {
  private ws: WebSocket | null = null;
  /** Epoch ms of the last inbound frame (message / relay ping / pong). */
  private lastActivityAt = 0;
  private livenessTimer: ReturnType<typeof setInterval> | null = null;

  constructor(
    private readonly url: string,
    private readonly keypair: Ed25519Keypair,
  ) {
    super();
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Connects and completes Ed25519 auth.  Resolves when relay is ready.
   *
   * `options.roomId` (12-char id derived from cwd, see `src/rooms.ts`) is
   * included in the hello so the relay can multiplex N concurrent peers
   * with the same Ed25519 pubkey but different rooms (one pi-ext per cwd).
   * Omitting `roomId` is backward-compat with old relays (treated as the
   * default "main" room server-side).
   *
   * Throws `RoomAlreadyOpenError` if the relay rejects the hello because
   * another peer already holds the (pubkey, room_id) tuple. Caller (e.g.
   * `_cmdStart`) maps that to a clearer UI message.
   */
  async connect(options: ConnectOptions = {}): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;

      ws.on("error", (err) => reject(err));
      const managedAuthClose = () => { this.emit("close"); reject(new Error("Managed relay closed during authentication")); };
      if (options.managed) ws.once("close", managedAuthClose);

      ws.on("open", async () => {
        try {
          await this._authenticate(ws, options);
          if (options.managed) {
            ws.off("close", managedAuthClose);
            if (ws.readyState !== WebSocket.OPEN) throw new Error("Managed relay closed during authentication");
          }

          // Auth done — wire persistent message handler. Every inbound frame
          // (data, plus the relay's keepalive ping/pong below) refreshes the
          // liveness clock.
          this.lastActivityAt = Date.now();
          ws.on("message", (raw) => {
            this.lastActivityAt = Date.now();
            const text = Buffer.isBuffer(raw) ? raw.toString() : String(raw);
            for (const line of text.split("\n")) {
              const trimmed = line.trim();
              if (trimmed) this.emit("message", trimmed);
            }
          });
          // The relay pings every ~25s; `ws` auto-replies Pong (keeping the
          // relay's view of us alive). The relay ignores client pings rather
          // than ponging, so these inbound pings — not a ping/pong we initiate
          // — are our liveness signal.
          ws.on("ping", () => { this.lastActivityAt = Date.now(); });
          ws.on("pong", () => { this.lastActivityAt = Date.now(); });

          ws.on("close", () => {
            this._stopLiveness();
            this.emit("close");
          });
          this._startLiveness(ws);
          resolve();
        } catch (err) {
          ws.terminate();
          reject(err);
        }
      });
    });
  }

  /** True only while the authenticated Relay WebSocket is currently open. */
  isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  /** Sends a raw line to the relay (caller is responsible for framing). */
  send(line: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error("relay: not connected");
    }
    this.ws.send(line);
  }

  private managedPendingBytes = 0;
  /** No retry queue. Completion accounting also bounds transports whose
   * bufferedAmount temporarily under-reports asynchronous writes. */
  sendManaged(line: string, fail: () => void): void {
    const ws = this.ws;
    const bytes = Buffer.byteLength(line) + 14;
    if (!ws || ws.readyState !== WebSocket.OPEN ||
        (ws.bufferedAmount ?? 0) + this.managedPendingBytes + bytes > MANAGED_SEND_LIMIT) {
      fail(); return;
    }
    this.managedPendingBytes += bytes;
    let completed = false;
    const complete = (error?: Error) => {
      if (completed) return;
      completed = true;
      this.managedPendingBytes -= bytes;
      if (error) fail();
    };
    try { ws.send(line, complete); } catch { complete(new Error("Managed send failed")); }
  }
  /** Fail-closed managed rooms must not drain queued protected output. */
  terminateManaged(): void {
    this._stopLiveness();
    const ws = this.ws; this.ws = null;
    ws?.terminate();
  }

  /**
   * Sends a control frame to the relay (not routed to app peer). Used for
   * out-of-band metadata updates like `room_meta_update`. Silently no-ops if
   * the WS isn't open (best-effort: control frames are observational; we
   * don't want them throwing inside SDK event callbacks).
   */
  sendControl(frame: Record<string, unknown>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(frame));
  }

  close(): void {
    this._stopLiveness();
    this.ws?.close();
    this.ws = null;
  }

  // ── Liveness watchdog ─────────────────────────────────────────────────────

  /** Force-close the WS when no inbound frame has arrived for
   *  `LIVENESS_TIMEOUT_MS` — see the constant's doc for why. `terminate()`
   *  fires `close`, which the owner turns into a reconnect. */
  private _startLiveness(ws: WebSocket): void {
    this._stopLiveness();
    this.livenessTimer = setInterval(() => {
      if (Date.now() - this.lastActivityAt > LIVENESS_TIMEOUT_MS) {
        this._stopLiveness();
        ws.terminate();
      }
    }, LIVENESS_CHECK_MS);
  }

  private _stopLiveness(): void {
    if (this.livenessTimer) {
      clearInterval(this.livenessTimer);
      this.livenessTimer = null;
    }
  }

  // ── Auth ────────────────────────────────────────────────────────────────────

  private async _authenticate(ws: WebSocket, opts: ConnectOptions): Promise<void> {
    const pubkeyB64 = Buffer.from(this.keypair.publicKey).toString("base64");
    const hello: HelloMsg = { type: "hello", pubkey: pubkeyB64 };
    if (opts.roomId) hello.room_id = opts.roomId;
    if (opts.roomMeta) hello.room_meta = opts.roomMeta;
    if (opts.managed && (opts.admitted && !await opts.admitted() || opts.current?.() === false)) throw new Error("Managed publication authority changed");
    this._rawSend(ws, JSON.stringify(hello), opts.managed);

    const challengeRaw = await this._nextMsg(ws);
    let challenge: ChallengeMsg | { type: "error"; code?: string; message?: string };
    try {
      challenge = JSON.parse(challengeRaw) as typeof challenge;
    } catch {
      throw new Error(`relay auth_failed: not JSON: ${challengeRaw}`);
    }
    if (challenge.type === "error") {
      const code = (challenge as { code?: string }).code ?? "";
      if (code === "room_already_open") {
        throw new RoomAlreadyOpenError(opts.roomId);
      }
      throw new Error(`relay rejected hello: ${code || (challenge as { message?: string }).message || "unknown"}`);
    }
    if (challenge.type !== "challenge" || !(challenge as ChallengeMsg).nonce) {
      throw new Error(`relay auth_failed: expected challenge, got ${challengeRaw}`);
    }

    if (opts.managed && (opts.admitted && !await opts.admitted() || opts.current?.() === false)) throw new Error("Managed publication authority changed");
    const nonce = Buffer.from((challenge as ChallengeMsg).nonce, "base64");
    const sig = ed25519Sign(this.keypair.secretKey, nonce);
    const auth: AuthMsg = {
      type: "auth",
      sig: Buffer.from(sig).toString("base64"),
    };
    this._rawSend(ws, JSON.stringify(auth), opts.managed);

    // Relay does not send an explicit "ok" — it simply starts routing.
    // Proceed immediately after sending auth.
  }

  /** Waits for the next single WS message with a timeout. */
  private _nextMsg(ws: WebSocket): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("relay auth timeout")),
        AUTH_TIMEOUT_MS,
      );
      ws.once("message", (raw) => {
        clearTimeout(timer);
        resolve(Buffer.isBuffer(raw) ? raw.toString() : String(raw));
      });
    });
  }

  private _rawSend(ws: WebSocket, data: string, managed = false): void {
    if (managed) this.sendManaged(data, () => ws.terminate());
    else ws.send(data);
  }
}
