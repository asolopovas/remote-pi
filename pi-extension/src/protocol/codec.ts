import type { SessionControlRequest, SessionControlResult, AgentRequest, LauncherRequest, ClientMessage, ServerMessage } from "./types.js";

const SERVER_TYPES = new Set<ServerMessage["type"]>([
  "session_control_status_result",
  "session_stop_result",
  "project_list_result",
  "launcher_status_result",
  "launcher_shutdown_result",
  "agent_list_result",
  "agent_launch_result",
  "agent_stop_result",
  "pair_ok",
  "pair_error",
  "user_input",
  "queued_message_state",
  "agent_chunk",
  "agent_done",
  "agent_message",
  "tool_request",
  "tool_result",
  "error",
  "cancelled",
  "pong",
  "bye",
  "session_history",
  // Plan/57 — interactive extension prompt (ask_user via pi-ask).
  "extension_ui_request",
]);

export class DecodeError extends Error {
  constructor(
    public readonly code: "invalid_message" | "unsupported_type",
    message: string,
  ) {
    super(message);
    this.name = "DecodeError";
  }
}

export function encodeClient(msg: ClientMessage): string {
  return JSON.stringify(msg) + "\n";
}

export function decodeServer(line: string): ServerMessage {
  let obj: unknown;
  try {
    obj = JSON.parse(line.trim());
  } catch (e) {
    throw new DecodeError("invalid_message", `not JSON: ${(e as Error).message}`);
  }
  if (
    !obj ||
    typeof obj !== "object" ||
    typeof (obj as Record<string, unknown>).type !== "string"
  ) {
    throw new DecodeError("invalid_message", "missing 'type'");
  }
  const t = (obj as Record<string, unknown>).type as string;
  if (!SERVER_TYPES.has(t as ServerMessage["type"])) {
    throw new DecodeError("unsupported_type", `unknown type: ${t}`);
  }
  if (t === "session_control_status_result" || t === "session_stop_result") return decodeSessionControlResult(obj);
  return obj as ServerMessage;
}

/** Strict boundary for the launch surface: no shell, flags, environment or aliases. */
export function decodeAgentRequest(value: unknown): AgentRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DecodeError("invalid_message", "Expected an agent request object");
  }
  const o = value as Record<string, unknown>;
  const text = (v: unknown, max: number): v is string =>
    typeof v === "string" && v.trim().length > 0 && v.length <= max && !/[\x00-\x1f\x7f-\x9f]/.test(v);
  if (!text(o.id, 128)) throw new DecodeError("invalid_message", "Invalid request ID (1–128 characters)");
  let keys: string[];
  switch (o.type) {
    case "agent_list": keys = ["type", "id"]; break;
    case "agent_launch":
      keys = ["type", "id", "launcher_id", "cwd", "name"];
      if (!text(o.launcher_id, 128)) throw new DecodeError("invalid_message", "Refresh launcher capabilities before starting an agent");
      if (!text(o.cwd, 4096) || (o.name !== undefined && !text(o.name, 80))) {
        throw new DecodeError("invalid_message", "Provide an existing directory and an optional name of 1–80 characters");
      }
      break;
    case "agent_stop":
      keys = ["type", "id", "agent_id"];
      if (!text(o.agent_id, 128)) throw new DecodeError("invalid_message", "Invalid managed agent ID");
      break;
    default: throw new DecodeError("unsupported_type", "Unknown agent request");
  }
  if (Object.keys(o).some((key) => !keys.includes(key))) {
    throw new DecodeError("invalid_message", "Unexpected agent request field");
  }
  return o as AgentRequest;
}

export const LAUNCHER_REQUEST_TYPES = new Set(["project_list", "launcher_status", "launcher_unlock", "launcher_pin_initialize", "launcher_lock", "launcher_shutdown", "project_launch", "launcher_agent_stop"]);
/** Exact additive contract; no remote filesystem paths, environment, or flags. */
export function decodeLauncherRequest(value: unknown): LauncherRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DecodeError("invalid_message", "Expected launcher request");
  const o = value as Record<string, unknown>;
  const text = (v: unknown, max = 128): v is string => typeof v === "string" && v.length > 0 && v.length <= max && !/[\x00-\x1f\x7f-\x9f]/.test(v);
  if (!text(o.id) || typeof o.type !== "string" || !LAUNCHER_REQUEST_TYPES.has(o.type)) throw new DecodeError("invalid_message", "Invalid launcher request");
  let keys = ["type", "id"];
  if (o.type !== "project_list" && o.type !== "launcher_status") {
    keys.push("launcher_id", "epoch");
    if (!text(o.launcher_id) || !text(o.epoch)) throw new DecodeError("invalid_message", "Refresh launcher security status");
  }
  if (o.type === "launcher_unlock" || o.type === "launcher_pin_initialize") { keys.push("pin"); if (typeof o.pin !== "string" || !/^\d{6,12}$/.test(o.pin)) throw new DecodeError("invalid_message", "Invalid PIN format"); }
  if (o.type === "project_launch") {
    keys.push("project_id", "name");
    if (!text(o.project_id) || o.name !== undefined && !text(o.name, 80)) throw new DecodeError("invalid_message", "Invalid project or agent name");
  }
  if (o.type === "launcher_agent_stop") { keys.push("agent_id"); if (!text(o.agent_id)) throw new DecodeError("invalid_message", "Invalid agent ID"); }
  if (Object.keys(o).some(k => !keys.includes(k))) throw new DecodeError("invalid_message", "Unexpected launcher field");
  return o as LauncherRequest;
}

const controlText = (v: unknown): v is string => typeof v === "string" && v.trim().length > 0 && v.length <= 128 && !/[\x00-\x1f\x7f-\x9f]/.test(v);
export function decodeSessionControlRequest(value: unknown): SessionControlRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DecodeError("invalid_message", "Invalid session control");
  const o = value as Record<string, unknown>;
  const keys = ["type", "id", "room_id", ...(o.type === "session_stop" ? ["token"] : [])];
  if (!["session_control_status", "session_stop"].includes(String(o.type)) || !controlText(o.id) || !controlText(o.room_id) || o.type === "session_stop" && !controlText(o.token) || Object.keys(o).some(k => !keys.includes(k))) throw new DecodeError("invalid_message", "Invalid session control");
  return o as SessionControlRequest;
}
export function decodeSessionControlResult(value: unknown): SessionControlResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DecodeError("invalid_message", "Invalid session control result");
  const o = value as Record<string, unknown>;
  const status = o.type === "session_control_status_result";
  const keys = ["type", "in_reply_to", "room_id", ...(status ? ["can_stop", "token", "reason", "access", "launching_host"] : ["state"])];
  if (!controlText(o.in_reply_to) || !controlText(o.room_id) || Object.keys(o).some(k => !keys.includes(k)) ||
      (status ? typeof o.can_stop !== "boolean" || (o.can_stop ? !controlText(o.token) : o.token !== undefined) || o.reason !== undefined && !controlText(o.reason)
        : o.type !== "session_stop_result" || !["requested", "stopped"].includes(String(o.state)))) throw new DecodeError("invalid_message", "Invalid session control result");
  if (status && o.access !== undefined) {
    const a = o.access as Record<string, unknown>;
    if (!a || typeof a !== "object" || Array.isArray(a) || Object.keys(a).length !== 2 || Object.keys(a).some(k => !["state", "expires_at"].includes(k)) ||
        !["unlocked", "locked", "expired", "unavailable"].includes(String(a.state)) ||
        (["unlocked", "expired"].includes(String(a.state)) ? !Number.isSafeInteger(a.expires_at) || Number(a.expires_at) < 0 : a.expires_at !== null) ||
        o.can_stop === true && a.state !== "unlocked") throw new DecodeError("invalid_message", "Invalid access snapshot");
  }
  if (status && o.launching_host !== undefined) {
    const h = o.launching_host as Record<string, unknown>;
    if (!h || typeof h !== "object" || Array.isArray(h) || Object.keys(h).length !== 2 || Object.keys(h).some(k => !["room_id", "launcher_id"].includes(k)) || !controlText(h.room_id) || !controlText(h.launcher_id)) throw new DecodeError("invalid_message", "Invalid launching host");
  }
  return o as SessionControlResult;
}
