// Host-local, offline preparation. No configuration, credentials or user extensions.
import { constants } from 'node:fs';
import { access, lstat, open, realpath, readdir, mkdir, writeFile, chmod, rename, rm } from 'node:fs/promises';
import { dirname, join, resolve, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';

function safeSource(s) {
  return s.uid === process.getuid() && !(s.mode & 0o002) && (!(s.mode & 0o020) || s.gid === process.getgid()) && !s.isSymbolicLink();
}
async function sourceRead(path, limit) {
  const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const s = await fd.stat();
    if (!safeSource(s) || !s.isFile() || s.size > limit) throw new Error('Unsafe or oversized runtime source');
    const data = Buffer.alloc(s.size + 1);
    let length = 0;
    while (length < data.length) {
      const read = await fd.read(data, length, data.length - length, null);
      if (!read.bytesRead) break;
      length += read.bytesRead;
    }
    if (length !== s.size) throw new Error('Runtime source changed during preparation');
    return data.subarray(0, length);
  } finally { await fd.close(); }
}

const destination = resolve(dirname(fileURLToPath(import.meta.url)), '../build/managed-runtime');
let cli;
for (const dir of (process.env.PATH ?? '').split(delimiter).filter(p => p.startsWith('/'))) {
  try { const p = join(dir, 'pi'); await access(p, constants.X_OK); cli = await realpath(p); break; } catch { /* next PATH entry */ }
}
if (!cli || !cli.endsWith('/dist/bundle/cli.js')) throw new Error('Install a bundled Pi 1.3.0 CLI on the host PATH');
const root = resolve(dirname(cli), '../..');
const pkg = JSON.parse((await sourceRead(join(root, 'package.json'), 131072)).toString());
if (pkg.name !== '@earendil-works/pi-coding-agent' || pkg.version !== '1.3.0') throw new Error('Managed runtime currently validates bundled Pi 1.3.0 only');
async function packageRoot(name) {
  for (let p = root; ; p = dirname(p)) {
    const candidate = join(p, 'node_modules', name);
    try { return await realpath(candidate); } catch {}
    if (dirname(p) === p) throw new Error('Required installed runtime dependency is missing');
  }
}
const stage = destination + '-' + randomUUID();
const manifest = { version: 1, piVersion: '1.3.0', files: {} };
let count = 0, bytes = 0;
async function copy(source, relative) {
  const s = await lstat(source);
  if (!safeSource(s)) throw new Error('Unsafe runtime source');
  if (++count > 15000 || (bytes += s.isFile() ? s.size : 0) > 160 * 1024 * 1024) throw new Error('Runtime closure exceeds bounds');
  if (s.isDirectory()) {
    await mkdir(join(stage, relative), { recursive: true, mode: 0o700 });
    for (const name of (await readdir(source)).sort()) await copy(join(source, name), join(relative, name));
  } else if (s.isFile() && s.size <= 32 * 1024 * 1024) {
    await mkdir(dirname(join(stage, relative)), { recursive: true, mode: 0o700 });
    const data = await sourceRead(source, 32 * 1024 * 1024);
    if (data.length !== s.size) throw new Error('Runtime source changed during preparation');
    manifest.files[relative] = createHash('sha256').update(data).digest('hex');
    await writeFile(join(stage, relative), data, { mode: 0o400 });
  } else throw new Error('Unsupported runtime source');
}
try {
  await mkdir(stage, { recursive: true, mode: 0o700 });
  for (const name of ['package.json', 'dist', 'README.md']) await copy(join(root, name), join('node_modules/@earendil-works/pi-coding-agent', name));
  // Pi's published 1.3 bundle externalizes these packages. Optional AWS
  // native signatures and ws accelerators are absent; built-in JS paths remain.
  for (const name of ['typebox', 'undici', '@silvia-odwyer/photon-node', 'jiti']) {
    const source = await packageRoot(name);
    const dep = JSON.parse((await sourceRead(join(source, 'package.json'), 131072)).toString());
    if (dep.name !== name || dep.version !== pkg.dependencies[name] || Object.keys(dep.dependencies ?? {}).length) throw new Error('Unexpected bundled runtime dependency contract');
    for (const entry of (await readdir(source)).sort()) {
      if (entry === 'node_modules') throw new Error('Unexpected nested runtime dependency tree');
      await copy(join(source, entry), join('node_modules', name, entry));
    }
  }
  const ai = await packageRoot('@earendil-works/pi-ai');
  if (JSON.parse((await sourceRead(join(ai, 'package.json'), 131072)).toString()).version !== pkg.version) throw new Error('Pi AI version mismatch');
  await copy(join(ai, 'dist/providers/data'), 'catalog');
  await writeFile(join(stage, 'manifest.json'), JSON.stringify(manifest), { mode: 0o400 });
  async function seal(p) { for (const e of await readdir(p, { withFileTypes: true })) if (e.isDirectory()) await seal(join(p, e.name)); await chmod(p, 0o500); }
  await seal(stage);
  // Never replace an in-use snapshot implicitly. Remove/reprepare explicitly.
  await rename(stage, destination);
  console.log('Prepared private bundled Pi 1.3.0 runtime closure (offline)');
} catch {
  const unseal = async p => { await chmod(p, 0o700); for (const e of await readdir(p, { withFileTypes: true })) if (e.isDirectory()) await unseal(join(p, e.name)); };
  await unseal(stage).then(() => rm(stage, { recursive: true, force: true })).catch(() => {});
  throw new Error('Could not prepare managed runtime; inspect the selected local Pi 1.3.0 installation, closure bounds and private snapshot destination (an existing snapshot is never replaced)');
}
