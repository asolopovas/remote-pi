#!/usr/bin/env node
import { LaunchRegistry } from "../session/launch_store.js";
import { setupLaunchPin } from "../session/launch_security.js";
import { pathToFileURL } from "node:url";

async function hiddenPin(label: string): Promise<string> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("PIN setup requires a local interactive terminal");
  // Disable terminal echo before advertising that PIN input is ready.
  process.stdin.setRawMode(true); process.stdin.resume();
  process.stdout.write(label);
  return new Promise((ok, fail) => {
    let value = "";
    const done = (error?: Error) => {
      process.stdin.off("data", input); process.stdin.setRawMode(false); process.stdin.pause(); process.stdout.write("\n");
      if (error) fail(error); else ok(value);
      value = "";
    };
    const input = (chunk: Buffer) => {
      for (const ch of chunk.toString()) {
        if (ch === "\u0003" || ch === "\u0004") { done(new Error("Cancelled")); return; }
        if (ch === "\r" || ch === "\n") { done(); return; }
        if (ch === "\u007f" || ch === "\b") value = value.slice(0, -1);
        else if (/^\d$/.test(ch) && value.length < 12) value += ch;
        else { done(new Error("PIN must contain only 6–12 digits")); return; }
      }
    };
    process.stdin.on("data", input);
  });
}
export async function launcherCli(args: string[]): Promise<void> {
  const registry = new LaunchRegistry();
  const [command, ...rest] = args;
  if (command === "pin-setup" && !rest.length) {
    let pin = await hiddenPin("New launcher PIN (6–12 digits, input hidden): ");
    let confirmation = await hiddenPin("Confirm PIN: ");
    try { if (pin !== confirmation) throw new Error("PINs do not match"); await setupLaunchPin(pin); }
    finally { pin = ""; confirmation = ""; }
    console.log("PIN verifier saved. Existing grants will fail closed on their next check.");
  } else if (command === "project-add" && rest.length >= 4) {
    const [name, cwd, ...flags] = rest;
    const folders: string[] = [];
    while (flags.length) { if (flags.shift() !== "--allow" || !flags.length) throw new Error("Repeat --allow <absolute-directory>"); folders.push(flags.shift()!); }
    console.log(JSON.stringify(await registry.add(name!, cwd!, folders), null, 2));
  } else if (command === "project-list" && !rest.length) {
    console.log(JSON.stringify(await registry.list(), null, 2));
  } else if (command === "project-remove" && rest.length === 1) {
    await registry.remove(rest[0]!); console.log("Project removed");
  } else throw new Error("Usage: remote-pi-launcher pin-setup | project-add <name> <absolute-cwd> --allow <absolute-folder> [--allow ...] | project-list | project-remove <project-id>");
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  launcherCli(process.argv.slice(2)).catch(error => { console.error(error instanceof Error ? error.message : "Launcher setup failed"); process.exitCode = 1; });
}
