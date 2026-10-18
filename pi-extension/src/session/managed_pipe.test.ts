import { test, expect } from "vitest";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { spawn, type ChildProcess } from "node:child_process";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { ManagedLineDecoder, managedFrame, parseManagedFrame, PIPE_LIMIT } from "./managed_pipe.js";

test("private managed framing preserves split multibyte RPC interleaving and bounds partial records", () => {
  const decoder = new ManagedLineDecoder(); const lines: string[] = [];
  const message = { type: "managed_control", epoch: "e", sequence: 1, message: { type: "user_message", id: "test", text: "Olá 🐧" } };
  const bytes = Buffer.from('{"type":"response","command":"get_state","success":true}\n' + managedFrame(message) + '{"type":"message_update","text":"你好"}\n');
  for (let i = 0; i < bytes.length; i++) decoder.push(bytes.subarray(i, i + 1), line => lines.push(line));
  decoder.end(); expect(lines).toHaveLength(3); expect(parseManagedFrame(lines[1]!)).toEqual(message);
  expect(parseManagedFrame(lines[0]!)).toBeUndefined();
  expect(() => parseManagedFrame('{"type":"remote_pi_managed_frame","message":{"type":"eval"}}')).toThrow();
  expect(() => managedFrame({ type: "managed_revoke", epoch: "e", env: {} })).toThrow();
  expect(() => new ManagedLineDecoder().push(Buffer.alloc(PIPE_LIMIT + 1, 65), () => {})).toThrow("large");
  const truncated = new ManagedLineDecoder(); truncated.push(Buffer.from("{"), () => {}); expect(() => truncated.end()).toThrow("Truncated");
});

test("private metadata has exact approved fields and validated bounded values", () => {
  const frame = { type: "managed_metadata", epoch: "e", meta: { working: true, model: "model", thinking: "high" } };
  expect(parseManagedFrame(managedFrame(frame))).toEqual(frame);
  for (const meta of [{ working: "yes" }, { working: true, cwd: "/secret" }, { working: true, model: "x".repeat(257) }, { working: true, model: "bad\nlabel" }, { working: true, thinking: "unknown" }, { working: true, thinking: ["low"] }, { working: true, thinking: null }]) {
    expect(() => managedFrame({ ...frame, meta })).toThrow();
  }
  expect(() => managedFrame({ ...frame, room_id: "arbitrary-room" })).toThrow();
});

test("real preload pipes init/control/revoke and RPC independently; malformed, oversized and EOF fail closed", async () => {
  const root = await mkdtemp(join(tmpdir(), "managed-pipe-test-")); const fixture = join(root, "fixture.mjs");
  const children: ChildProcess[] = [];
  await writeFile(fixture, `import { childBridge } from '${resolve("dist/session/managed_pipe.js")}'; const b = childBridge(); b.send({type:'remote_pi_managed_ready',name:'fixture',room_id:'room',ok:true}); b.events.on('message', m => { if(m.type === 'managed_init') b.send({type:'managed_metadata',epoch:m.epoch,meta:{working:false,model:'fixture',thinking:'low'}}); if(m.type === 'managed_control') b.send({type:'managed_event',epoch:m.epoch,message:{type:'pong',in_reply_to:m.message.id}}); }); process.stdin.on('data', chunk => process.stdout.write(chunk)); setInterval(() => {}, 1000);`);
  const start = () => {
    const child = spawn(process.execPath, ["--import", resolve("dist/session/managed_preload.js"), fixture], { env: { ...process.env, REMOTE_PI_SANDBOX_CHILD: "1" }, stdio: ["pipe", "pipe", "pipe"] });
    children.push(child); child.stderr?.on("data", () => {}); return child;
  };
  try {
    const child = start(); const lines: string[] = []; const decode = new ManagedLineDecoder();
    child.stdout!.on("data", (b: Buffer) => decode.push(b, line => lines.push(line)));
    await expect.poll(() => lines.some(line => (parseManagedFrame(line) as { type?: string } | undefined)?.type === "remote_pi_managed_ready")).toBe(true);
    const rpc = '{"type":"get_state","id":"Olá 🐧"}\n';
    const bytes = Buffer.from(managedFrame({ type: "managed_init", owner: "owner", room_id: "room", epoch: "e" }) + rpc + managedFrame({ type: "managed_control", epoch: "e", sequence: 1, message: { type: "ping", id: "control" } }));
    for (let i = 0; i < bytes.length; i++) child.stdin!.write(bytes.subarray(i, i + 1));
    await expect.poll(() => lines.includes(rpc)).toBe(true);
    await expect.poll(() => lines.some(line => (parseManagedFrame(line) as { type?: string } | undefined)?.type === "managed_metadata")).toBe(true);
    await expect.poll(() => lines.some(line => (parseManagedFrame(line) as { message?: { in_reply_to?: string } } | undefined)?.message?.in_reply_to === "control")).toBe(true);
    child.stdin!.write(managedFrame({ type: "managed_revoke", epoch: "new" }));
    child.stdin!.end(); await expect.poll(() => child.exitCode !== null || child.signalCode !== null).toBe(true);
    for (const data of ['{"type":"remote_pi_managed_frame","message":{"type":"eval"}}\n', 'x'.repeat(PIPE_LIMIT + 1)]) {
      const invalid = start(); invalid.stdout!.on("data", () => {}); invalid.stdin!.on("error", () => {});
      invalid.stdin!.write(data);
      await expect.poll(() => invalid.exitCode !== null || invalid.signalCode !== null, { timeout: 5000 }).toBe(true);
    }
  } finally {
    for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    await rm(root, { recursive: true, force: true });
  }
}, 15000);
