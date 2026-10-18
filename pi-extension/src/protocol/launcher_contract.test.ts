import { test, expect } from "vitest";
import { decodeLauncherRequest, decodeServer, encodeClient } from "./codec.js";
import type { LauncherRequest, LauncherResult } from "./types.js";

test("frozen launcher wire golden requests/results, strict fields and no remote paths", () => {
  const requests: LauncherRequest[] = [
    { type: "launcher_status", id: "status" }, { type: "project_list", id: "projects" },
    { type: "launcher_pin_initialize", id: "initialize", launcher_id: "host", epoch: "generation", pin: "654321" },
    { type: "launcher_unlock", id: "unlock", launcher_id: "host", epoch: "generation", pin: "654321" },
    { type: "launcher_lock", id: "lock", launcher_id: "host", epoch: "generation" },
    { type: "launcher_shutdown", id: "shutdown", launcher_id: "host", epoch: "generation" },
    { type: "project_launch", id: "launch", launcher_id: "host", epoch: "generation", project_id: "registered", name: "reviewer" },
    { type: "launcher_agent_stop", id: "stop", launcher_id: "host", epoch: "generation", agent_id: "owned" },
  ];
  for (const request of requests) expect(decodeLauncherRequest(JSON.parse(encodeClient(request)))).toEqual(request);
  const status = { launcher_id: "host", epoch: "generation", configured: true, unlocked: false, expires_at: null, cooldown_until: 0 };
  const results: LauncherResult[] = [
    { type: "launcher_status_result", in_reply_to: "status", status }, // old host
    { type: "launcher_status_result", in_reply_to: "new-status", status: { ...status, launcher_api: 2, unlocked: true } },
    { type: "project_list_result", in_reply_to: "projects", projects: [{ project_id: "registered", name: "Project", cwd: "/approved/project", allowed_folders: ["/approved/project"] }] },
    { type: "launcher_shutdown_result", in_reply_to: "shutdown", stopped: false, status },
  ];
  for (const result of results) expect(decodeServer(JSON.stringify(result))).toEqual(result);
  for (const extra of [{ cwd: "/arbitrary" }, { allowed_folders: ["/tmp"] }, { env: {} }, { command: "sh" }, { owner: "alias" }, { pin: 123456 }]) expect(() => decodeLauncherRequest({ ...requests[2], ...extra })).toThrow();
  expect(() => decodeLauncherRequest({ ...requests[5], epoch: undefined })).toThrow();
  expect(() => decodeLauncherRequest({ type: "launcher_unlock", id: "x", launcher_id: "host", epoch: "e", pin: "123" })).toThrow();
});

 test("initialization rejects aliases, paths, extras and invalid PIN/authority without echo", () => {
   const base = { type: "launcher_pin_initialize", id: "init", launcher_id: "host", epoch: "e", pin: "654321" };
   for (const patch of [{ pin: "123" }, { pin: 654321 }, { pin: "123456\n" }, { epoch: "" }, { owner: "other" }, { cwd: "/tmp" }, { id: "\u0000" }]) expect(() => decodeLauncherRequest({ ...base, ...patch })).toThrow();
 });
