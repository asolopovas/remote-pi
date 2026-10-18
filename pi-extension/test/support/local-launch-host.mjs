// Real production launcher/transport; only the RPC child loses networking.
// Like secure_launcher.integration.test.ts, no provider turn can leave the sandbox.
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join, isAbsolute } from 'node:path';
import { createInterface } from 'node:readline';
const spawn = childProcess.spawn;
childProcess.spawn = (command, args, options) => spawn(command, command === '/bin/bwrap' ? ['--unshare-net', ...args] : args, options);
syncBuiltinESMExports();
const mode = process.argv[2];
if (!['valid', 'missing', 'invalid'].includes(mode)) throw new Error('fixture mode required');
const root = await mkdtemp(join(tmpdir(), 'cross-launch-'));
process.env.HOME = root;
process.env.USERPROFILE = root;
let relay, host, launcher;
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  clearTimeout(deadline);
  try { await launcher?.shutdown(); } finally {
    host?.close(); relay?.kill('SIGKILL');
    if (relay) await new Promise(ok => relay.exitCode !== null || relay.signalCode !== null ? ok() : relay.once('exit', ok));
    await rm(root, { recursive: true, force: true });
  }
}
const deadline = setTimeout(() => { console.error('local launch fixture deadline'); close().finally(() => process.exit(1)); }, 90000);
process.on('SIGTERM', () => close().then(() => process.exit(0)));
process.stdin.resume();
process.stdin.on('end', () => close().then(() => process.exit(0)));
try {
  // All host state is private and synthetic, set before importing production modules.
  process.env.REMOTE_PI_HOME = join(root, 'remote');
  process.env.PI_CODING_AGENT_DIR = join(root, 'credentials');
  const { SecureLauncher } = await import('../../dist/session/secure_launcher.js');
  const { LaunchRegistry } = await import('../../dist/session/launch_store.js');
  const { setupLaunchPin } = await import('../../dist/session/launch_security.js');
  const { generateEd25519Keypair } = await import('../../dist/pairing/crypto.js');
  const { RelayClient } = await import('../../dist/transport/relay_client.js');
  const { decodeLauncherRequest } = await import('../../dist/protocol/codec.js');
  await mkdir(process.env.PI_CODING_AGENT_DIR, { mode: 0o700 });
  await writeFile(join(process.env.PI_CODING_AGENT_DIR, 'auth.json'), JSON.stringify({ 'openai-codex': { type: 'oauth', access: 'synthetic', refresh: 'synthetic', expires: Date.now() + 86400000 } }), { mode: 0o600 });
  await writeFile(join(process.env.PI_CODING_AGENT_DIR, 'settings.json'), JSON.stringify({ defaultProvider: 'openai-codex', defaultModel: 'gpt-6.1-sol' }), { mode: 0o600 });
  const relayBinary = process.env.REMOTE_PI_TEST_RELAY_BINARY;
  if (!relayBinary || !isAbsolute(relayBinary)) throw new Error('Root workflow must supply an absolute REMOTE_PI_TEST_RELAY_BINARY built for this host');
  relay = spawn(relayBinary, [join(root, 'mesh.db')], { stdio: ['ignore', 'pipe', 'inherit'] });
  const lines = createInterface({ input: relay.stdout });
  const port = await new Promise((ok, fail) => {
    lines.once('line', line => /^\d+$/.test(line) ? ok(Number(line)) : fail(new Error('invalid relay port')));
    relay.once('error', fail);
    relay.once('exit', code => fail(new Error(`relay exited ${code}`)));
  });
  lines.close();
  const url = `http://127.0.0.1:${port}`;
  process.env.REMOTE_PI_RELAY = url;
  const project = join(root, 'project'); await mkdir(project);
  const registry = new LaunchRegistry(join(root, 'store'));
  await registry.add('local fixture', project, [project]);
  await setupLaunchPin('654321', registry.dir);
  const hostKey = generateEd25519Keypair();
  const ownerKey = generateEd25519Keypair();
  const owner = Buffer.from(ownerKey.publicKey).toString('base64');
  let extensionPath = resolve('dist/index.js');
  if (mode !== 'valid') {
    const release = join(root, 'release'); await mkdir(release);
    await symlink(resolve('dist'), join(release, 'dist'));
    await symlink(resolve('node_modules'), join(release, 'node_modules'));
    if (mode === 'invalid') {
      await mkdir(join(release, 'build/managed-runtime'), { recursive: true });
      await writeFile(join(release, 'build/managed-runtime/manifest.json'), '{}');
    }
    extensionPath = join(release, 'dist/index.js');
  }
  launcher = new SecureLauncher({ cwd: project, rootRoom: () => 'fixture-root', extensionPath, registry, keypair: async () => hostKey, paired: async peer => peer === owner, current: () => !closing });
  host = new RelayClient(url.replace('http:', 'ws:'), hostKey);
  host.on('error', error => { console.error(error.message); });
  host.on('message', async line => {
    const frame = JSON.parse(line);
    if (!frame.ct || frame.peer !== owner) return;
    const request = JSON.parse(Buffer.from(frame.ct, 'base64').toString());
    let reply;
    try {
      reply = request.type === 'agent_list'
        ? await launcher.legacy(owner, request, async () => true)
        : await launcher.handle(owner, decodeLauncherRequest(request), async () => true);
    } catch { return; }
    host.send(JSON.stringify({ peer: owner, ct: Buffer.from(JSON.stringify(reply)).toString('base64') }));
  });
  await host.connect({ roomId: 'fixture-root', roomMeta: { name: 'Local fixture', cwd: project } });
  console.log(JSON.stringify({ url, host: Buffer.from(hostKey.publicKey).toString('base64'), seed: Buffer.from(ownerKey.secretKey).toString('base64') }));
} catch (error) {
  console.error(error);
  await close(); process.exit(1);
}
