import { constants } from "node:fs";
import { lstat, open, opendir, readFile } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
export class LaunchPreflightError extends Error {}
/** Writable binds share host inodes. Reject hardlinks, special files and nested
 * mounts instead of pretending a path allowlist protects outside inode aliases. */
export interface PreflightBudget { entries: number; deadline: number }
export async function scanWritableRoot(root: FileHandle, registeredPath: string, limit = 100_000, deadlineMs = 5000, budget: PreflightBudget = { entries: 0, deadline: Date.now() + deadlineMs }): Promise<void> {
  const mounts = (await readFile("/proc/self/mountinfo", "utf8")).split("\n").map(line => line.split(" ")[4]?.replace(/\\([0-7]{3})/g, (_m, octal: string) => String.fromCharCode(parseInt(octal, 8)))).filter((p): p is string => !!p);
  if (mounts.some(p => p.startsWith(registeredPath + "/"))) throw new LaunchPreflightError("Registered writable folder contains a nested mount; remove it locally before launch");
  const rootStat = await root.stat({ bigint: true });
  const until = budget.deadline;
  const walk = async (dir: FileHandle, depth = 0): Promise<void> => {
    if (depth > 128 || Date.now() > until) throw new LaunchPreflightError("Registered writable tree exceeds depth or elapsed preflight limits");
    for await (const entry of await opendir(`/proc/self/fd/${dir.fd}`)) {
      const name = entry.name;
      if (++budget.entries > limit || Date.now() > until) throw new LaunchPreflightError("Registered writable folder exceeds launch preflight bounds; choose a smaller project locally");
      const path = `/proc/self/fd/${dir.fd}/${name}`;
      const s = await lstat(path, { bigint: true });
      if (s.isSymbolicLink()) continue;
      if (s.dev !== rootStat.dev) throw new LaunchPreflightError("Registered writable folder contains a nested filesystem");
      if (s.isFile()) {
        if (s.nlink > 1n) throw new LaunchPreflightError("Registered writable folder contains hardlinked files; prepare a private normal-file project copy locally");
      } else if (s.isDirectory()) {
        const child = await open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        try {
          const actual = await child.stat({ bigint: true });
          if (s.dev !== actual.dev || s.ino !== actual.ino) throw new LaunchPreflightError("Registered writable tree changed during preflight");
          await walk(child, depth + 1);
        } finally { await child.close(); }
      } else throw new LaunchPreflightError("Registered writable folder contains a socket, device or FIFO; remove it locally before launch");
    }
  };
  try { await walk(root); }
  catch (error) { if (error instanceof LaunchPreflightError) throw error; throw new LaunchPreflightError("Registered writable folder is inaccessible or changed during preflight"); }
}
