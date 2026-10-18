import { EventEmitter } from "node:events";
import { StringDecoder } from "node:string_decoder";
import type { ChildProcess } from "node:child_process";
import type { Writable } from "node:stream";
export const PIPE_FRAME = "remote_pi_managed_frame";
export const PIPE_LIMIT = 6_000_000;
const KINDS = new Set(["managed_init", "managed_revoke", "managed_control", "remote_pi_managed_ready", "managed_event", "managed_metadata"]);
export interface ManagedMetadata { working: boolean; model?: string; thinking?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" }
export function decodeManagedMetadata(value: unknown): ManagedMetadata {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid managed metadata");
  const m = value as Record<string, unknown>;
  if (Object.keys(m).some(k => !["working", "model", "thinking"].includes(k)) || typeof m.working !== "boolean" ||
      m.model !== undefined && (typeof m.model !== "string" || m.model.length < 1 || m.model.length > 256 || /[\x00-\x1f\x7f-\x9f]/.test(m.model)) ||
      m.thinking !== undefined && (typeof m.thinking !== "string" || !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(m.thinking))) throw new Error("Invalid managed metadata");
  return { working: m.working, ...(m.model !== undefined ? { model: m.model as string } : {}), ...(m.thinking !== undefined ? { thinking: m.thinking as ManagedMetadata["thinking"] } : {}) };
}
export function validateManagedMessage(value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid private managed message");
  const m = value as Record<string, unknown>;
  const text = (v: unknown, max = 256) => typeof v === "string" && v.length > 0 && v.length <= max && !/[\x00-\x1f]/.test(v);
  let keys: string[];
  switch (m.type) {
    case "managed_init": keys = ["type", "owner", "room_id", "epoch"]; if (!text(m.owner) || !text(m.room_id) || !text(m.epoch)) throw new Error("Invalid managed init"); break;
    case "managed_revoke": keys = ["type", "epoch"]; if (!text(m.epoch)) throw new Error("Invalid managed revocation"); break;
    case "managed_control": keys = ["type", "epoch", "sequence", "message"]; if (!text(m.epoch) || !Number.isSafeInteger(m.sequence) || Number(m.sequence) < 1 || !m.message || typeof m.message !== "object") throw new Error("Invalid managed control frame"); break;
    case "managed_metadata": keys = ["type", "epoch", "meta"]; if (!text(m.epoch)) throw new Error("Invalid managed metadata epoch"); decodeManagedMetadata(m.meta); break;
    case "managed_event": keys = ["type", "epoch", "message"]; if (!text(m.epoch) || !m.message || typeof m.message !== "object") throw new Error("Invalid managed event"); break;
    case "remote_pi_managed_ready": keys = ["type", "name", "room_id", "ok"]; if (!text(m.name) || !text(m.room_id) || typeof m.ok !== "boolean") throw new Error("Invalid managed ready"); break;
    default: throw new Error("Unknown private managed message");
  }
  if (Object.keys(m).some(k => !keys.includes(k))) throw new Error("Unexpected private managed field");
}
export function managedFrame(message: unknown): string {
  if (!message || typeof message !== "object" || !KINDS.has(String((message as { type?: unknown }).type))) throw new Error("Invalid private managed frame");
  validateManagedMessage(message);
  const line = JSON.stringify({ type: PIPE_FRAME, message }) + "\n";
  if (Buffer.byteLength(line) > PIPE_LIMIT) throw new Error("Managed frame too large");
  return line;
}
/** UTF8 streaming-safe LF framing; no logging and bounded partial records. */
export class ManagedLineDecoder {
  private decoder = new StringDecoder("utf8");
  private partial = "";
  push(chunk: Buffer, line: (value: string) => void): void {
    this.partial += this.decoder.write(chunk);
    let end: number;
    while ((end = this.partial.indexOf("\n")) >= 0) {
      const record = this.partial.slice(0, end + 1); this.partial = this.partial.slice(end + 1);
      if (Buffer.byteLength(record) > PIPE_LIMIT) throw new Error("Managed record too large");
      line(record);
    }
    if (Buffer.byteLength(this.partial) > PIPE_LIMIT) throw new Error("Managed partial record too large");
  }
  end(): void { this.partial += this.decoder.end(); if (this.partial.length) throw new Error("Truncated managed record"); }
}
export function parseManagedFrame(line: string): unknown | undefined {
  let o: unknown;
  try { o = JSON.parse(line); } catch { return undefined; }
  if (!o || typeof o !== "object" || (o as { type?: unknown }).type !== PIPE_FRAME) return undefined;
  const frame = o as { type: string; message?: unknown };
  if (Object.keys(frame).some(k => k !== "type" && k !== "message") || !frame.message || typeof frame.message !== "object" || !KINDS.has(String((frame.message as { type?: unknown }).type))) throw new Error("Malformed managed frame");
  validateManagedMessage(frame.message);
  return frame.message;
}
export function writeManaged(output: Writable, message: unknown, fail: () => void): void {
  if (output.destroyed || output.writableLength > PIPE_LIMIT || !output.write(managedFrame(message))) fail();
}
const pipeChildren = new WeakSet<ChildProcess>();
export function markPipeChild(child: ChildProcess): void { pipeChildren.add(child); }
export function sendToManagedChild(child: ChildProcess, message: unknown): void {
  if (pipeChildren.has(child)) {
    if (!child.stdin) throw new Error("Managed stdin closed");
    writeManaged(child.stdin, message, () => { child.kill("SIGKILL"); });
  } else if (child.connected) child.send(message as Parameters<ChildProcess["send"]>[0]);
  else throw new Error("Managed channel closed");
}
export function managedChildConnected(child: ChildProcess): boolean { return pipeChildren.has(child) ? !!child.stdin && !child.stdin.destroyed && child.exitCode === null && child.signalCode === null : child.connected; }
export interface ChildBridge { events: EventEmitter; send(message: unknown): void; connected: boolean }
const KEY = Symbol.for("remote-pi.private-managed-bridge");
export function childBridge(): ChildBridge | undefined { return (globalThis as typeof globalThis & { [KEY]?: ChildBridge })[KEY]; }
export function installChildBridge(bridge: ChildBridge): void { (globalThis as typeof globalThis & { [KEY]?: ChildBridge })[KEY] = bridge; }
