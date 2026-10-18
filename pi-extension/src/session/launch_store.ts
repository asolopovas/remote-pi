import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, unlink, rmdir, link } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, parse, resolve } from "node:path";
import { randomUUID } from "node:crypto";

export const launchStoreDir = () => join(homedir(), ".pi", "remote", "launcher");
export interface FolderIdentity { path: string; dev: string; ino: string; ancestors: { path: string; dev: string; ino: string }[] }
export interface LaunchProject { id: string; name: string; cwd: FolderIdentity; folders: FolderIdentity[] }
export interface ProjectRegistry { version: 1; projects: LaunchProject[] }

/** Local-only paths. Refuse symlink components, dot traversal and system/home roots. */
export async function identifyFolder(path: string): Promise<FolderIdentity> {
  if (!isAbsolute(path) || path.split("/").some(p => p === "." || p === "..") || path.includes("\0")) throw new Error("An absolute non-traversing directory is required");
  const canonical = resolve(path);
  if (canonical === join(homedir(), ".pi") || canonical.startsWith(join(homedir(), ".pi") + "/")) throw new Error("Host Pi credentials and launcher storage cannot be registered");
  if (canonical === parse(canonical).root || canonical === homedir() || ["/home", "/usr", "/etc", "/var", "/tmp", "/proc", "/sys", "/dev", "/run"].some(p => canonical === p || canonical.startsWith(p + "/") && p !== "/tmp" && p !== "/home")) throw new Error("System and home roots cannot be registered");
  const ancestors: FolderIdentity["ancestors"] = [];
  let current = parse(canonical).root;
  for (const segment of canonical.slice(current.length).split("/")) {
    current = join(current, segment);
    const s = await lstat(current, { bigint: true });
    if (!s.isDirectory() || s.isSymbolicLink()) throw new Error("Directory symlinks are not permitted");
    ancestors.push({ path: current, dev: String(s.dev), ino: String(s.ino) });
  }
  if (await realpath(canonical) !== canonical) throw new Error("Noncanonical directory");
  const leaf = ancestors.at(-1)!;
  return { ...leaf, ancestors };
}
export async function checkFolder(folder: FolderIdentity): Promise<void> {
  const actual = await identifyFolder(folder.path);
  if (JSON.stringify(actual) !== JSON.stringify(folder)) throw new Error("Registered directory was replaced; register it again locally");
}
export async function privateDirectory(dir: string): Promise<void> {
  // Check before creation: recursive mkdir would follow an existing symlink.
  let at = parse(resolve(dir)).root;
  for (const part of resolve(dir).slice(at.length).split("/")) {
    at = join(at, part);
    let s;
    try { s = await lstat(at); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      try { await mkdir(at, { mode: 0o700 }); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
      s = await lstat(at);
    }
    if (!s.isDirectory() || s.isSymbolicLink()) throw new Error("Unsafe launcher storage path");
  }
  const s = await lstat(dir);
  if (s.uid !== process.getuid?.() || (s.mode & 0o077) !== 0) throw new Error("Launcher storage must be owned by this user and mode 0700");
}
export async function readPrivateJson<T>(dir: string, name: string): Promise<T> {
  await privateDirectory(dir);
  const fd = await open(join(dir, name), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const s = await fd.stat();
    if (!s.isFile() || s.uid !== process.getuid?.() || (s.mode & 0o077) !== 0 || s.size > 131072) throw new Error("Unsafe launcher configuration");
    return JSON.parse(await fd.readFile("utf8")) as T;
  } finally { await fd.close(); }
}
export async function writePrivateJson(dir: string, name: string, data: unknown): Promise<void> {
  await privateDirectory(dir);
  const temp = join(dir, "." + randomUUID());
  const fd = await open(temp, "wx", 0o600);
  try { await fd.writeFile(JSON.stringify(data)); await fd.sync(); }
  finally { await fd.close(); }
  try { await rename(temp, join(dir, name)); const d = await open(dir, "r"); try { await d.sync(); } finally { await d.close(); } }
  finally { await unlink(temp).catch(() => {}); }
}
/** Absence must be positively established with lstat: dangling links are not absent. */
export async function launchPinAbsent(dir: string): Promise<boolean> {
  await privateDirectory(dir);
  try { await lstat(join(dir, "pin.json")); return false; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return true; throw error; }
}
/** Caller holds the transaction lock. Atomic create-only publication, never rename-overwrite.
 * Authority is checked after all staging I/O, directly before submitting publication. */
export async function createPrivatePin(dir: string, data: unknown, authorize: () => Promise<void>, current: () => void): Promise<void> {
  await privateDirectory(dir);
  const temp = join(dir, "." + randomUUID());
  const fd = await open(temp, "wx", 0o600);
  try {
    try { await fd.writeFile(JSON.stringify(data)); await fd.sync(); } finally { await fd.close(); }
    await authorize();
    current();
    await link(temp, join(dir, "pin.json"));
    const d = await open(dir, "r"); try { await d.sync(); } finally { await d.close(); }
  } finally { await unlink(temp).catch(() => {}); }
}
export class LaunchRegistry {
  constructor(readonly dir = launchStoreDir()) {}
  async list(): Promise<LaunchProject[]> {
    const data = await readPrivateJson<ProjectRegistry>(this.dir, "projects.json");
    if (data.version !== 1 || !Array.isArray(data.projects) || data.projects.length > 64) throw new Error("Invalid project registry");
    for (const p of data.projects) {
      if (!p || typeof p.id !== "string" || typeof p.name !== "string" || !Array.isArray(p.folders) || !p.folders.length || p.folders.length > 16) throw new Error("Invalid project registry");
      await checkFolder(p.cwd);
      for (const f of p.folders) await checkFolder(f);
      if (!p.folders.some(f => p.cwd.path === f.path || p.cwd.path.startsWith(f.path + "/"))) throw new Error("Project cwd is not allowed");
    }
    return data.projects;
  }
  async add(name: string, cwd: string, allowed: string[]): Promise<LaunchProject> {
    return withLaunchStoreLock(this.dir, () => this.addLocked(name, cwd, allowed));
  }
  private async addLocked(name: string, cwd: string, allowed: string[]): Promise<LaunchProject> {
    if (!name.trim() || name.length > 80 || /[\x00-\x1f]/.test(name) || !allowed.length || allowed.length > 16) throw new Error("Provide a name and 1–16 explicitly allowed directories");
    const p: LaunchProject = { id: randomUUID(), name, cwd: await identifyFolder(cwd), folders: await Promise.all([...new Set(allowed)].map(identifyFolder)) };
    if (!p.folders.some(f => p.cwd.path === f.path || p.cwd.path.startsWith(f.path + "/"))) throw new Error("cwd must be within an explicitly allowed directory");
    let projects: LaunchProject[];
    try { projects = (await readPrivateJson<ProjectRegistry>(this.dir, "projects.json")).projects; }
    catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; projects = []; }
    if (!Array.isArray(projects) || projects.length >= 64 || projects.some(e => e.name === name)) throw new Error("Duplicate name or registry full");
    await writePrivateJson(this.dir, "projects.json", { version: 1, projects: [...projects, p] });
    return p;
  }
  async remove(id: string): Promise<void> {
    return withLaunchStoreLock(this.dir, () => this.removeLocked(id));
  }
  private async removeLocked(id: string): Promise<void> {
    const data = await readPrivateJson<ProjectRegistry>(this.dir, "projects.json");
    if (!Array.isArray(data.projects) || !data.projects.some(p => p.id === id)) throw new Error("Unknown project ID");
    await writePrivateJson(this.dir, "projects.json", { version: 1, projects: data.projects.filter(p => p.id !== id) });
  }
}

/** Cross-process storage serialization. Never auto-break a potentially live lock. */
export async function withLaunchStoreLock<T>(dir: string, operation: () => Promise<T>): Promise<T> {
  await privateDirectory(dir);
  const lock = join(dir, "transaction.lock");
  let held = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { await mkdir(lock, { mode: 0o700 }); held = true; break; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    await new Promise(r => setTimeout(r, 20));
  }
  if (!held) throw new Error("Launcher configuration is busy; inspect stale transaction lock locally");
  try { return await operation(); } finally { await rmdir(lock); }
}
