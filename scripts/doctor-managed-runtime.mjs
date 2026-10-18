#!/usr/bin/env node
// Read-only diagnosis: use this checkout's validator on the explicitly named
// package, not code imported from a possibly old installed extension.
import { realpath, stat } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

async function main() {
  const args = process.argv.slice(2);
  const selected = args.length === 0 ? process.env.EXTENSION_ROOT : args[0];
  if (args.length > 1 || !selected || !isAbsolute(selected)) {
    console.error('usage: make doctor EXTENSION_ROOT=/absolute/extension/root\n   or: node scripts/doctor-managed-runtime.mjs /absolute/extension/root');
    process.exitCode = 2;
    return;
  }
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 19)) throw new Error('Node 22.19+ required');
  const checkout = fileURLToPath(new URL('../', import.meta.url));
  const validator = resolve(checkout, 'pi-extension/dist/session/launch_runtime.js');
  try { await stat(validator); } catch {
    throw new Error('Missing built checkout validator; build this checkout with the documented offline pnpm runner first. Nothing was prepared or replaced.');
  }
  console.log(`Selected extension root: ${selected}`);
  console.log('This path is operator-supplied; the active phone host path has NOT been discovered or proven.');
  const canonical = await realpath(selected);
  console.log(`Canonical extension root: ${canonical}`);
  console.log(`Validator: ${validator}`);
  const { managedRuntime } = await import(pathToFileURL(validator).href);
  const runtime = await managedRuntime(canonical);
  console.log(`PASS: managed runtime integrity/ownership/closure: ${runtime.root}`);
  console.log('Read-only check only: no credentials, PIN, model defaults, sandbox availability, active process, or phone readiness validated; no sessions restarted.');
}

main().catch(error => {
  console.error(`FAIL: ${error instanceof Error ? error.message : 'managed runtime check failed'}`);
  console.error('No preparation, runtime replacement, install, or service restart performed.');
  process.exitCode = 1;
});
