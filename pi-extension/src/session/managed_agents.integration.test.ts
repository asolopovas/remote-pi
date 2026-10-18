import { test, expect, vi } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";
import { generateEd25519Keypair, ed25519Verify } from "../pairing/crypto.js";
import { ManagedAgents, type ManagedSpawn } from "./managed_agents.js";

/** Real installed Pi + source extension, but exclusively ephemeral identity,
 * session/config roots and a loopback challenge-verifying relay. No model turn,
 * production relay, OS keyring operation, pairing mutation or installation. */
test("real Pi children publish distinct authenticated rooms, create fresh same-cwd sessions and stop", async () => {
  const root = mkdtempSync(join(tmpdir(), "phone-pi-integration-"));
  const cwd = join(root, "project"); mkdirSync(cwd);
  const identityDir = join(root, ".pi", "remote"); mkdirSync(identityDir, { recursive: true });
  const keypair = generateEd25519Keypair();
  writeFileSync(join(identityDir, "identity.json"), JSON.stringify({ pk: Buffer.from(keypair.publicKey).toString("base64"), sk: Buffer.from(keypair.secretKey).toString("base64") }), { mode: 0o600 });
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>(r => server.once("listening", r));
  const address = server.address(); if (!address || typeof address === "string") throw new Error("missing server port");
  const authenticatedRooms: string[] = [];
  server.on("connection", ws => {
    const nonce = randomBytes(32); let room: string | undefined;
    ws.on("message", raw => {
      const message = JSON.parse(raw.toString()) as { type: string; pubkey?: string; room_id?: string; sig?: string };
      if (message.type === "hello") {
        expect(message.pubkey).toBe(Buffer.from(keypair.publicKey).toString("base64")); room = message.room_id;
        ws.send(JSON.stringify({ type: "challenge", nonce: nonce.toString("base64") }));
      } else if (message.type === "auth") {
        expect(ed25519Verify(keypair.publicKey, nonce, Buffer.from(message.sig ?? "", "base64"))).toBe(true);
        if (room) authenticatedRooms.push(room);
      }
    });
  });
  const cli = join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "cli.js");
  const sessionIds: string[] = [];
  const children: ChildProcess[] = [];
  const realSpawn = vi.fn<ManagedSpawn>().mockImplementation((_command, args, options) => {
    const child = spawn(process.execPath, [cli, ...args], options);
    children.push(child);
    let buffer = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      let end: number;
      while ((end = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        try {
          const frame = JSON.parse(line) as { command?: string; data?: { sessionId?: unknown } };
          if (frame.command === "get_state" && typeof frame.data?.sessionId === "string") sessionIds.push(frame.data.sessionId);
        } catch { /* discard non-RPC output, never print logs */ }
      }
      if (buffer.length > 65_536) buffer = "";
    });
    return child;
  });
  const manager = new ManagedAgents({ cwd, extensionPath: resolve("src/index.ts"), spawn: realSpawn,
    env: { ...process.env, HOME: root, USERPROFILE: root, REMOTE_PI_HOME: root,
      PI_CODING_AGENT_DIR: join(root, ".pi", "agent"), PI_PACKAGE_DIR: dirname(dirname(cli)),
      REMOTE_PI_RELAY: `http://127.0.0.1:${address.port}` }, readinessMs: 15_000 });
  try {
    const [first, second] = await Promise.all(["one", "two"].map(id => manager.handle("fixture-owner", { type: "agent_launch", id, launcher_id: manager.launcherId, cwd, name: "reviewer" }, async () => true)));
    expect(first.type).toBe("agent_launch_result"); expect(second.type).toBe("agent_launch_result");
    if (first.type !== "agent_launch_result" || second.type !== "agent_launch_result") throw new Error(JSON.stringify([first, second]));
    expect(first.agent.state).toBe("running"); expect(second.agent.state).toBe("running");
    expect(first.agent.room_id).not.toBe(second.agent.room_id);
    await expect.poll(() => authenticatedRooms.sort()).toEqual([first.agent.room_id, second.agent.room_id].sort());
    // Pi persists a new JSONL lazily (no initial model turn here). Runtime
    // session IDs, rather than file counts, prove same-cwd independence.
    expect(sessionIds).toHaveLength(2);
    expect(new Set(sessionIds).size).toBe(2);
    const stopped = await manager.handle("fixture-owner", { type: "agent_stop", id: "stop", agent_id: first.agent.agent_id }, async () => true);
    expect(stopped).toMatchObject({ type: "agent_stop_result", agent: { state: "stopped" } });
    // Closing the real IPC channel exercises the same child-side orphan guard
    // as launcher loss, without killing the test process or touching live Pis.
    const remaining = children.find(child => child.exitCode === null && child.signalCode === null);
    if (!remaining) throw new Error("Second Pi unexpectedly exited before launcher-loss probe");
    remaining.disconnect();
    await expect.poll(() => remaining.exitCode !== null || remaining.signalCode !== null,
      { timeout: 8_000 }).toBe(true);
    await manager.shutdown();
    await expect.poll(() => server.clients.size).toBe(0);
  } finally {
    await manager.shutdown();
    for (const client of server.clients) client.terminate();
    await new Promise<void>(r => server.close(() => r()));
    rmSync(root, { recursive: true, force: true });
  }
}, 30_000);
