import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { constants } from "node:fs";
import { access, lstat, open, realpath, stat, unlink } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { managedRuntime, type ExpectedModel } from "./launch_runtime.js";
import type { FileHandle } from "node:fs/promises";
import { scanWritableRoot, LaunchPreflightError } from "./launch_preflight.js";
import { checkFolder, type LaunchProject } from "./launch_store.js";

// Paths come only from the host's fixed Pi agent directory, never a request.
const AUTH_ERROR = "Inspect local Pi auth.json: use a regular user-owned private 0600 file with valid stored credentials; symlinks are not supported";
const SETTINGS_ERROR = "Inspect local Pi settings.json: use valid model defaults in a bounded user-owned regular file (symlinks to safe files are supported)";
async function modelJson(path: string, settings: boolean): Promise<Record<string, unknown>> {
  const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const s = await fd.stat();
    // Settings are public metadata; ordinary user/group-writable 0664 is supported.
    if (!s.isFile() || s.uid !== process.getuid?.() || s.size > 131072 || (s.mode & (settings ? 0o002 : 0o077)) !== 0) throw new Error("Unsafe model file");
    const bytes = Buffer.alloc(131073);
    try {
      let length = 0;
      while (length < bytes.length) {
        const { bytesRead } = await fd.read(bytes, length, bytes.length - length, null);
        if (!bytesRead) break;
        length += bytesRead;
      }
      if (length > 131072) throw new Error("Model file exceeds bounds");
      const value: unknown = JSON.parse(bytes.subarray(0, length).toString("utf8"));
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid model file");
      return value as Record<string, unknown>;
    } finally { bytes.fill(0); }
  } finally { await fd.close(); }
}
export interface SandboxPlan { command: string; args: string[]; env: NodeJS.ProcessEnv; fds: number[]; expectedModel: ExpectedModel; close(): Promise<void> }
/** Entire Pi runs inside a private mount/PID/user namespace. Network is deliberately
 * shared for model/Relay access: this is filesystem isolation, not a network policy. */
export async function launchSandbox(project: LaunchProject, extension: string, piArgs: string[], name: string): Promise<SandboxPlan> {
  if (process.platform !== "linux") throw new LaunchPreflightError("Secure launching requires Linux with working bubblewrap; inspect the host sandbox locally");
  await checkFolder(project.cwd).catch(() => { throw new LaunchPreflightError("Registered project changed or is inaccessible; inspect and register it again locally"); });
  const handles: FileHandle[] = [];
  const budget = { entries: 0, deadline: Date.now() + 5000 };
  const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME ?? "", ".pi", "agent");
  const args = ["--die-with-parent", "--new-session", "--unshare-user", "--disable-userns", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--cap-drop", "ALL", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/home", "--dir", "/home/pi", "--dir", "/home/pi/.pi", "--dir", "/home/pi/.pi/agent"];
  const pin = async (path: string, destination: string, writable: boolean) => {
    const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    handles.push(fd);
    args.push(writable ? "--bind" : "--ro-bind", `/proc/self/fd/${handles.length + 3}`, destination);
    return fd;
  };
  let stage = "runtime";
  let expectedModel: ExpectedModel;
  try {
    await access("/bin/bwrap", constants.X_OK);
    for (const path of ["/usr", "/bin", "/lib", "/lib64", "/etc/ssl", "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf"]) {
      try { const canonical = await realpath(path); await pin(canonical, path, false); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
    const [major, minor] = process.versions.node.split(".").map(Number);
    if (process.release.name !== "node" || major! < 22 || major === 22 && minor! < 19) throw new LaunchPreflightError("Secure launch requires a Node runtime supporting bundled Pi 1.3.0 (Node 22.19 or newer); inspect the host runtime locally");
    const node = await realpath(process.execPath);
    await pin(node, node, false);
    const extensionRoot = resolve(dirname(extension), "..");
    const runtime = await managedRuntime(extensionRoot);
    const piRoot = runtime.root;
    const dependencies = await realpath(join(extensionRoot, "node_modules"));
    await pin(piRoot, piRoot, false);
    await pin(extensionRoot, extensionRoot, false);
    await pin(dependencies, dependencies, false);
    stage = "settings";
    let settingsPath: string | undefined;
    try { settingsPath = await realpath(join(agentDir, "settings.json")); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new LaunchPreflightError(SETTINGS_ERROR);
      // Only an absent optional source is ignored, not a dangling configured link.
      const source = await lstat(join(agentDir, "settings.json")).catch(error => {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw new LaunchPreflightError(SETTINGS_ERROR);
      });
      if (source) throw new LaunchPreflightError(SETTINGS_ERROR);
    }
    const canonicalAgentDir = await realpath(agentDir).catch(() => resolve(agentDir));
    stage = "project";
    for (const folder of project.folders) {
      await checkFolder(folder);
      if ([piRoot, extensionRoot, dependencies, dirname(node), "/home/pi", resolve(agentDir), canonicalAgentDir].some(p => folder.path === p || folder.path.startsWith(p + "/") || p.startsWith(folder.path + "/")) || settingsPath?.startsWith(folder.path + "/")) throw new LaunchPreflightError("Registered project overlaps protected runtime or Pi configuration; register a separate project locally");
      const fd = await pin(folder.path, folder.path, true);
      const s = await fd.stat({ bigint: true });
      if (String(s.dev) !== folder.dev || String(s.ino) !== folder.ino) throw new Error("Registered directory changed during launch");
      await checkFolder(folder);
      await scanWritableRoot(fd, folder.path, 100_000, 5000, budget);
    }
    // Pin the exact cwd as well, even when it is below an allowed root.
    const cwdFd = await pin(project.cwd.path, project.cwd.path, true);
    const cwdStat = await cwdFd.stat({ bigint: true });
    if (String(cwdStat.dev) !== project.cwd.dev || String(cwdStat.ino) !== project.cwd.ino) throw new Error("Registered project was replaced");
    await checkFolder(project.cwd).catch(() => { throw new LaunchPreflightError("Registered project changed or is inaccessible; inspect and register it again locally"); });
    // Credentials are copied through a read-only descriptor into private tmpfs,
    // never mount host HOME or remote identity, settings, history, or sockets.
    {
      stage = "auth";
      let credentials: Record<string, unknown>;
      try { credentials = await modelJson(join(agentDir, "auth.json"), false); }
      catch { throw new LaunchPreflightError(AUTH_ERROR); }
      stage = "settings";
      let defaults: { defaultProvider?: string; defaultModel?: string } = {};
      try {
        const value = settingsPath ? await modelJson(settingsPath, true) : {};
        if (value.defaultProvider !== undefined) {
          if (typeof value.defaultProvider !== "string" || !/^[a-z0-9_-]{1,128}$/.test(value.defaultProvider)) throw new Error("Invalid provider");
          defaults.defaultProvider = value.defaultProvider;
        }
        if (value.defaultModel !== undefined) {
          if (typeof value.defaultModel !== "string" || !value.defaultModel.length || value.defaultModel.length > 256 || /[\x00-\x1f\x7f]/.test(value.defaultModel)) throw new Error("Invalid model");
          defaults.defaultModel = value.defaultModel;
        }
      } catch { throw new LaunchPreflightError(SETTINGS_ERROR); }
      stage = "auth";
      const providers = Object.keys(credentials).filter(p => /^[a-z0-9_-]{1,128}$/.test(p)).sort();
      const provider = defaults.defaultProvider ?? providers[0];
      if (!provider || !credentials[provider] || typeof credentials[provider] !== "object") throw new LaunchPreflightError("Configure stored credentials for the selected model provider locally");
      const credential = credentials[provider] as Record<string, unknown>;
      if (credential.type === "api_key" ? typeof credential.key !== "string" || !credential.key || credential.key.startsWith("!") : credential.type !== "oauth" || typeof credential.access !== "string" || !credential.access || typeof credential.refresh !== "string") throw new LaunchPreflightError("Secure launch requires a stored literal API key or OAuth credential; host credential commands are not exposed");
      // Refuse custom model files rather than silently dropping endpoint/API
      // overrides or running host credential/provider commands in the child.
      for (const file of ["models.json", "models.jsonc"]) {
        if (await lstat(join(agentDir, file)).then(() => true, error => { if (error.code === "ENOENT") return false; throw error; })) throw new LaunchPreflightError("Custom model configuration cannot be inherited securely; configure a bundled default without model overrides locally");
      }
      if (!defaults.defaultProvider || !defaults.defaultModel) throw new LaunchPreflightError("Configure both defaultProvider and defaultModel in local Pi settings before launching a phone agent");
      expectedModel = runtime.catalog(defaults.defaultProvider, defaults.defaultModel);
      defaults = { defaultProvider: expectedModel.provider, defaultModel: expectedModel.id };
      stage = "copy";
      const copiedFile = async (data: unknown, destination: string) => {
        const path = join(tmpdir(), "remote-pi-launch-" + randomUUID());
        const fd = await open(path, "wx+", 0o600);
        try {
          await unlink(path); // No named file ever contains credential plaintext.
          const bytes = Buffer.from(JSON.stringify(data));
          try { await fd.write(bytes, 0, bytes.length, 0); } finally { bytes.fill(0); }
          handles.push(fd);
          args.push("--perms", "0600", "--file", String(handles.length + 3), destination);
        } catch (error) { await fd.close(); await unlink(path).catch(() => {}); throw error; }
      };
      await copiedFile({ [provider]: credentials[provider] }, "/home/pi/.pi/agent/auth.json");
      await copiedFile(defaults, "/home/pi/.pi/agent/settings.json");
    }
    stage = "runtime";
    const cli = runtime.cli;
    for (const path of [cli, extension, join(extensionRoot, "dist", "session", "managed_preload.js")]) {
      if (!(await stat(path)).isFile()) throw new LaunchPreflightError("Secure launch runtime incomplete; rebuild the host extension and inspect the installed Pi locally");
    }
    args.push("--chdir", project.cwd.path, "--", node, "--import", join(extensionRoot, "dist", "session", "managed_preload.js"), cli, ...piArgs, "--provider", expectedModel.provider, "--model", expectedModel.id, "--no-approve", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--session-dir", "/home/pi/.pi/agent/sessions");
    // No inherited parent secrets/config/worker identities. Provider credentials
    // from auth.json remain exposed to this sandbox's project code, by design.
    const env: NodeJS.ProcessEnv = { HOME: "/home/pi", PATH: "/usr/bin:/bin", LANG: "C.UTF-8", PI_CODING_AGENT_DIR: "/home/pi/.pi/agent", PI_SKIP_VERSION_CHECK: "1", PI_OFFLINE: "1", PI_TELEMETRY: "0", REMOTE_PI_DAEMON: "1", REMOTE_PI_MANAGED_CHILD: "1", REMOTE_PI_SANDBOX_CHILD: "1", REMOTE_PI_DIRECT_CONFIG: JSON.stringify({ agent_name: name, auto_start_relay: false }) };
    return { command: "/bin/bwrap", args, env, expectedModel, fds: handles.map(f => f.fd), close: async () => { await Promise.all(handles.map(f => f.close())); } };
  } catch (error) {
    await Promise.all(handles.map(f => f.close()));
    if (error instanceof LaunchPreflightError) throw error;
    if (stage === "project") throw new LaunchPreflightError("Registered project changed or is inaccessible; inspect and register it again locally");
    if (["ENOENT", "EACCES", "EPERM", "ELOOP", "ENOTDIR", "EROFS", "ENOSPC", "ERR_MODULE_NOT_FOUND"].includes((error as NodeJS.ErrnoException).code ?? "")) {
      throw new LaunchPreflightError(stage === "runtime" ? "Secure launch runtime unavailable; inspect local bubblewrap, Node, installed Pi and the built extension" : "Secure launch could not prepare private model files; inspect host temporary storage locally");
    }
    throw error;
  }
}
