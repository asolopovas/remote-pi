import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { decodeAgentRequest, decodeServer, encodeClient } from "./codec.js";
import type { AgentRequest, ManagedAgent, ServerMessage } from "./types.js";

describe("agent request codec (plan 94 frozen contract)", () => {
  test("Dart input boundaries match strict host validation", () => {
    const cases: Array<{ cwd: string; name?: string; valid: boolean }> = JSON.parse(readFileSync(new URL(
      "../../../app/test/protocol/fixtures/agent_input_validation.json", import.meta.url,
    ), "utf8"));
    for (const { valid, ...input } of cases) {
      const parse = () => decodeAgentRequest({ type: "agent_launch", id: "boundary", launcher_id: "launcher-1", ...input });
      if (valid) expect(parse).not.toThrow();
      else expect(parse).toThrow();
    }
  });
  test("Dart consumer fixture agrees with the typed host wire contract", () => {
    // This exact file is also exercised by app/test/agents/agent_repository_test.dart.
    const fixture: unknown = JSON.parse(readFileSync(new URL(
      "../../../app/test/protocol/fixtures/agent_management.json", import.meta.url,
    ), "utf8"));
    const agent: ManagedAgent = {
      agent_id: "agent-1", name: "Phone agent-1", cwd: "/projects/pi",
      room_id: "room-agent-1", state: "running",
    };
    const requests: AgentRequest[] = [
      { type: "agent_list", id: "list-1" },
      { type: "agent_launch", id: "launch-1", launcher_id: "launcher-1", cwd: "/projects/pi", name: "Phone agent" },
      { type: "agent_launch", id: "launch-2", launcher_id: "launcher-1", cwd: "/projects/pi" },
      { type: "agent_stop", id: "stop-1", agent_id: "agent-1" },
    ];
    const replies: ServerMessage[] = [
      { type: "agent_list_result", in_reply_to: "list-1", available: true, launcher_id: "launcher-1",
        cwd: "/projects/pi", max_agents: 4, agents: [] },
      { type: "agent_list_result", in_reply_to: "list-2", available: false,
        reason: "Managed children cannot launch agents", cwd: "/projects/pi", max_agents: 4, agents: [] },
      { type: "agent_launch_result", in_reply_to: "launch-1", agent },
      { type: "agent_stop_result", in_reply_to: "stop-1", agent: { ...agent, state: "stopped" } },
      { type: "error", in_reply_to: "launch-2", code: "invalid_message", message: "Directory does not exist" },
    ];
    expect(fixture).toEqual({ requests, replies });
    for (const request of requests) expect(decodeAgentRequest(JSON.parse(encodeClient(request)))).toEqual(request);
    for (const reply of replies) expect(decodeServer(JSON.stringify(reply))).toEqual(reply);
  });
  test.each([
    { type: "agent_list", id: "list" },
    { type: "agent_launch", id: "launch", launcher_id: "launcher-1", cwd: "/project" },
    { type: "agent_launch", id: "launch", launcher_id: "launcher-1", cwd: "/project", name: "Reviewer" },
    { type: "agent_stop", id: "stop", agent_id: "server-owned-id" },
  ] as const)("valid $type", request => {
    expect(decodeAgentRequest(JSON.parse(encodeClient(request)))).toEqual(request);
  });
  test.each([
    null, [], "agent_list", {}, { type: "unknown", id: "x" },
    { type: "agent_launch", id: "x", cwd: "/p", launcher_id: undefined },
    { type: "agent_list" }, { type: "agent_list", id: 3 }, { type: "agent_list", id: "" },
    { type: "agent_list", id: "\n" }, { type: "agent_list", id: "x".repeat(129) },
    { type: "agent_launch", id: "x", cwd: " " }, { type: "agent_launch", id: "x", cwd: [] },
    { type: "agent_launch", id: "x", cwd: "/a\u0000" }, { type: "agent_launch", id: "x", cwd: "x".repeat(4097) },
    { type: "agent_launch", id: "x", cwd: "/a", name: null }, { type: "agent_launch", id: "x", cwd: "/a", name: "" },
    { type: "agent_launch", id: "x", cwd: "/a", name: "x".repeat(81) }, { type: "agent_launch", id: "x", cwd: "/a", name: "a\u0085" },
    { type: "agent_launch", id: "x", cwd: "/a", flags: ["--continue"] },
    { type: "agent_launch", id: "x", cwd: "/a", env: {} },
    { type: "agent_launch", id: "x", cwd: "/a", prompt: "paid initial prompt" },
    { type: "agent_launch", id: "x", cwd: "/a", owner: "alias" },
    { type: "agent_launch", id: "x", cwd: "/a", binary: "/bin/sh" },
    { type: "agent_stop", id: "x", agent_id: 123 }, { type: "agent_stop", id: "x", agent_id: "\r" },
    { type: "agent_stop", id: "x", agent_id: "a", pid: 123 },
  ])("rejects malformed/extraneous shape %#", request => {
    const withLauncher = request && typeof request === "object" && "type" in request && request.type === "agent_launch"
      ? { launcher_id: "launcher-1", ...request } : request;
    expect(() => decodeAgentRequest(withLauncher)).toThrow();
  });
  test("accepts frozen result envelopes", () => {
    const agent = { agent_id: "id", name: "reviewer-id", cwd: "/project", room_id: "room", state: "running" };
    for (const result of [
      { type: "agent_list_result", in_reply_to: "list", available: true, cwd: "/project", max_agents: 4, agents: [agent] },
      { type: "agent_launch_result", in_reply_to: "launch", agent },
      { type: "agent_stop_result", in_reply_to: "stop", agent: { ...agent, state: "stopped" } },
    ]) expect(decodeServer(JSON.stringify(result))).toEqual(result);
  });
});
