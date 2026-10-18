import { test, expect, vi } from "vitest";
import { randomBytes } from "node:crypto";
import { mkdtemp, mkdir, rm, writeFile, symlink, chmod, cp, stat, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { SecureLauncher } from "./secure_launcher.js";
import { LaunchRegistry } from "./launch_store.js";
import { setupLaunchPin } from "./launch_security.js";
import { generateEd25519Keypair, ed25519Verify } from "../pairing/crypto.js";
import type { LauncherRequest, ServerMessage } from "../protocol/types.js";
import { decodeLauncherRequest } from "../protocol/codec.js";

// Keep the parent loopback proxy outside the child's disconnected network NS.
vi.mock("node:child_process", async importOriginal => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, spawn: ((command: string, args: string[], options: import("node:child_process").SpawnOptions) => actual.spawn(command, command === "/bin/bwrap" ? ["--unshare-net", ...args] : args, options)) };
});

test("real sandbox Pi + parent-only signing/rooms, gated dispatch, direct child control and Lock, owner shutdown", async () => {
  const root = await mkdtemp(join(tmpdir(), "secure-launch-integration-"));
  // Freeze a built installed-package layout, with only the existing cached deps.
  const release = join(root, "installed-release"); await mkdir(release);
  await cp(resolve("dist"), join(release, "dist"), { recursive: true });
  await mkdir(join(release, "build"));
  await cp(resolve("build/managed-runtime"), join(release, "build/managed-runtime"), { recursive: true });
  await cp(resolve("package.json"), join(release, "package.json"));
  await symlink(resolve("node_modules"), join(release, "node_modules"));
  const project = join(root, "project"); await mkdir(project);
  const registry = new LaunchRegistry(join(root, "store"));
  const entry = await registry.add("fixture", project, [project]);
  const keypair = generateEd25519Keypair();
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>(ok => server.once("listening", ok));
  const address = server.address(); if (!address || typeof address === "string") throw new Error("No loopback address");
  const rooms = new Map<string, WebSocket>(); const replies: ServerMessage[] = [];
  const metadata: { room_id: string; meta: { working: boolean; model?: string; thinking?: string } }[] = [];
  server.on("connection", ws => {
    const nonce = randomBytes(32); let room: string | undefined;
    ws.on("message", data => {
      const frame = JSON.parse(data.toString());
      if (frame.type === "hello") {
        expect(frame.pubkey).toBe(Buffer.from(keypair.publicKey).toString("base64")); room = frame.room_id;
        ws.send(JSON.stringify({ type: "challenge", nonce: nonce.toString("base64") }));
      } else if (frame.type === "auth") {
        expect(ed25519Verify(keypair.publicKey, nonce, Buffer.from(frame.sig, "base64"))).toBe(true);
        if (room) rooms.set(room, ws);
      } else if (frame.type === "room_meta_update") metadata.push(frame);
      else if (frame.ct) replies.push(JSON.parse(Buffer.from(frame.ct, "base64").toString("utf8")));
    });
    ws.on("close", () => { if (room) rooms.delete(room); });
  });
  vi.stubEnv("REMOTE_PI_RELAY", `http://127.0.0.1:${address.port}`);
  const credentials = join(root, "credentials"); await mkdir(credentials);
  await writeFile(join(credentials, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: "synthetic", refresh: "synthetic", expires: Date.now() + 86400000 } }), { mode: 0o600 });
  const settings = join(root, "synthetic-settings.json");
  await writeFile(settings, JSON.stringify({ defaultProvider: "openai-codex", defaultModel: "gpt-6.1-sol", extensions: ["must-not-load"] }));
  await chmod(settings, 0o664);
  await symlink(settings, join(credentials, "settings.json"));
  vi.stubEnv("PI_CODING_AGENT_DIR", credentials);
  let paired = true;
  const launcher = new SecureLauncher({ cwd: project, rootRoom: () => "actual-published-root-not-derived-from-project", extensionPath: join(release, "dist/index.js"), registry, keypair: async () => keypair, paired: async () => paired, current: () => true });
  const handle = (request: LauncherRequest, owner = "owner-a") => launcher.handle(owner, decodeLauncherRequest(request), async () => paired);
  const security = (type: "launcher_unlock" | "launcher_lock" | "launcher_shutdown", id: string): LauncherRequest => ({ type, id, launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, ...(type === "launcher_unlock" ? { pin: "654321" } : {}) } as LauncherRequest);
  try {
    expect(await handle({ type: "project_list", id: "locked-list" })).toMatchObject({ type: "error" });
    expect(await handle({ type: "project_launch", id: "absent-pin", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, project_id: entry.id })).toMatchObject({ type: "error" });
    await setupLaunchPin("654321", registry.dir);
    expect(await handle(security("launcher_unlock", "unlock"))).toMatchObject({ type: "launcher_status_result", status: { unlocked: true } });
    expect(await handle({ type: "project_list", id: "projects" })).toEqual({ type: "project_list_result", in_reply_to: "projects", projects: [{ project_id: entry.id, name: "fixture", cwd: project, allowed_folders: [project] }] });
    expect(await launcher.legacy("owner-a", { type: "agent_launch", id: "bypass", launcher_id: launcher.agents.launcherId, cwd: "/tmp" }, async () => true)).toMatchObject({ type: "error" });
    const originalList = registry.list.bind(registry);
    let releaseList!: () => void; let enteredList!: () => void;
    const parked = new Promise<void>(r => { releaseList = r; });
    const entered = new Promise<void>(r => { enteredList = r; });
    const listSpy = vi.spyOn(registry, "list").mockImplementationOnce(async () => { enteredList(); await parked; return originalList(); });
    const racing = handle({ type: "project_launch", id: "race-lock", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, project_id: entry.id });
    await entered; launcher.lock(); releaseList();
    expect(await racing).toMatchObject({ type: "error" }); expect(rooms.size).toBe(0); listSpy.mockRestore();
    await handle(security("launcher_unlock", "unlock-after-race"));
    const request = { type: "project_launch", id: "start", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, project_id: entry.id } as const;
    const launched = await handle(request);
    expect(launched, JSON.stringify(launched)).toMatchObject({ type: "agent_launch_result", agent: { state: "running", cwd: project } });
    if (launched.type !== "agent_launch_result") throw new Error(JSON.stringify(launched));
    await expect.poll(() => rooms.has(launched.agent.room_id)).toBe(true);
    await expect.poll(() => metadata.some(m => m.room_id === launched.agent.room_id && m.meta.working === false && typeof m.meta.model === "string" && typeof m.meta.thinking === "string")).toBe(true);
    const ws = rooms.get(launched.agent.room_id)!;
    const send = (inner: unknown, peer = "owner-a") => ws.send(JSON.stringify({ peer, ct: Buffer.from(JSON.stringify(inner)).toString("base64") }));
    send({ type: "session_control_status", id: "origin-status", room_id: launched.agent.room_id });
    await expect.poll(() => replies.find(r => r.type === "session_control_status_result" && r.in_reply_to === "origin-status")).toMatchObject({
      can_stop: true,
      access: { state: "unlocked", expires_at: expect.any(Number) },
      launching_host: { room_id: "actual-published-root-not-derived-from-project", launcher_id: launcher.agents.launcherId },
    });
    send({ type: "ping", id: "direct" });
    await expect.poll(() => replies.some(r => r.type === "pong" && r.in_reply_to === "direct")).toBe(true);
    send({ type: "list_models", id: "models" });
    await expect.poll(() => replies.some(r => r.type === "models_list" && r.in_reply_to === "models" && r.models.some(m => m.provider === "openai-codex"))).toBe(true);
    send({ type: "session_sync", id: "history", limit: 10 });
    await expect.poll(() => replies.some(r => r.type === "session_history" && r.in_reply_to === "history")).toBe(true);
    send({ type: "ping", id: "wrong-owner" }, "owner-b");
    await new Promise(r => setTimeout(r, 100)); expect(replies.some(r => r.type === "pong" && r.in_reply_to === "wrong-owner")).toBe(false);
    expect(await handle(security("launcher_lock", "lock"))).toMatchObject({ status: { unlocked: false } });
    send({ type: "session_control_status", id: "locked-origin-status", room_id: launched.agent.room_id });
    await expect.poll(() => replies.find(r => r.type === "session_control_status_result" && r.in_reply_to === "locked-origin-status")).toMatchObject({
      can_stop: false, access: { state: "locked", expires_at: null },
      launching_host: { room_id: "actual-published-root-not-derived-from-project", launcher_id: launcher.agents.launcherId },
    });
    const lockedControls = replies.find(r => r.type === "session_control_status_result" && r.in_reply_to === "locked-origin-status");
    expect(lockedControls).not.toHaveProperty("token");
    send({ type: "ping", id: "locked-direct" });
    send({ type: "user_message", id: "locked-prompt", text: "must not execute" });
    await new Promise(r => setTimeout(r, 150));
    expect(replies.some(r => r.type === "pong" && r.in_reply_to === "locked-direct" || r.type === "user_input" && r.id === "locked-prompt")).toBe(false);
    expect(replies).toContainEqual(expect.objectContaining({ type: "error", in_reply_to: "locked-prompt", code: "invalid_message" }));
    expect(await handle(request)).toMatchObject({ type: "error" });
    expect(await handle(security("launcher_unlock", "unlock-again"))).toMatchObject({ status: { unlocked: true } });
    send({ type: "ping", id: "still-running" });
    await expect.poll(() => replies.some(r => r.type === "pong" && r.in_reply_to === "still-running")).toBe(true);
    expect(await handle(security("launcher_unlock", "unlock-b"), "owner-b")).toMatchObject({ status: { unlocked: true } });
    expect(await handle({ type: "launcher_agent_stop", id: "foreign-stop", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, agent_id: launched.agent.agent_id }, "owner-b")).toMatchObject({ type: "error" });
    const foreignShutdown = await handle(security("launcher_shutdown", "shutdown-b"), "owner-b");
    expect(foreignShutdown).toMatchObject({ type: "launcher_shutdown_result", stopped: true, status: { unlocked: false } });
    expect(rooms.has(launched.agent.room_id)).toBe(true);
    await handle(security("launcher_unlock", "unlock-final"));
    const stopped = await handle({ type: "launcher_agent_stop", id: "stop-a", launcher_id: launcher.agents.launcherId, epoch: launcher.security.epoch, agent_id: launched.agent.agent_id });
    expect(stopped).toMatchObject({ type: "agent_stop_result", agent: { state: "stopped", agent_id: launched.agent.agent_id } });
    expect((await stat(settings)).mode & 0o777).toBe(0o664);
    const shutdown = await handle(security("launcher_shutdown", "shutdown-a"));
    expect(shutdown).toMatchObject({ type: "launcher_shutdown_result", stopped: true, status: { unlocked: false } });
    await expect.poll(() => rooms.size).toBe(0);
    paired = false;
    expect(await handle({ type: "launcher_status", id: "revoked" })).toMatchObject({ type: "error" });
  } finally {
    await launcher.shutdown();
    for (const ws of server.clients) ws.terminate();
    await new Promise<void>(r => server.close(() => r()));
    vi.unstubAllEnvs();
    const unseal = async (p: string): Promise<void> => { await chmod(p, 0o700); for (const e of await readdir(p, { withFileTypes: true })) if (e.isDirectory()) await unseal(join(p, e.name)); };
    await unseal(root);
    await rm(root, { recursive: true, force: true });
  }
}, 35000);
