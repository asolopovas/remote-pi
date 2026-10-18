import { EventEmitter } from "node:events";
import { PassThrough, type Writable } from "node:stream";
import { ManagedLineDecoder, parseManagedFrame, installChildBridge, writeManaged } from "./managed_pipe.js";

// Internal entry point loaded only by the secure launcher before Pi starts.
// The original stdin is demultiplexed: ordinary RPC records are unchanged.
if (process.env.REMOTE_PI_SANDBOX_CHILD !== "1") throw new Error("Managed preload requires sandbox mode");
const original = process.stdin;
const rpc = new PassThrough();
const events = new EventEmitter();
// Pi's RPC output guard redirects extension stdout writes to stderr. Preserve
// the original writer before its takeover, without altering ordinary RPC.
const rawWrite = process.stdout.write.bind(process.stdout);
const output = { write: rawWrite, get writableLength() { return process.stdout.writableLength; }, get destroyed() { return process.stdout.destroyed; } } as Writable;
let closed = false;
const bridge = { events, connected: true, send(message: unknown) { if (!closed) writeManaged(output, message, fail); } };
installChildBridge(bridge);
const fail = () => {
  if (closed) return;
  closed = true; bridge.connected = false; events.emit("disconnect"); rpc.end();
  const timer = setTimeout(() => process.kill(process.pid, "SIGKILL"), 1000); timer.unref();
  process.kill(process.pid, "SIGTERM");
};
Object.defineProperty(process, "stdin", { value: rpc });
const decoder = new ManagedLineDecoder();
original.on("data", (chunk: Buffer) => {
  try { decoder.push(chunk, line => {
    const message = parseManagedFrame(line);
    if (message !== undefined) {
      const type = (message as { type: string }).type;
      if (!["managed_init", "managed_control", "managed_revoke"].includes(type)) throw new Error("Invalid parent frame direction");
      events.emit("message", message);
    } else {
      if (rpc.writableLength > 6_000_000 || !rpc.write(line)) fail();
    }
  }); } catch { fail(); }
});
original.once("end", () => { try { decoder.end(); } catch { /* truncated input is fatal */ } fail(); });
original.once("error", fail);
process.stdout.once("error", fail);
