import { test, expect } from "vitest";
import { constants } from "node:fs";
import { mkdtemp, mkdir, link, chmod, open, readFile, rm, writeFile } from "node:fs/promises";
import { execFileSync, spawn } from "node:child_process";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { scanWritableRoot } from "./launch_preflight.js";

test("preflight rejects outside hardlink aliases, special files, inaccessible and bounded trees", async () => {
  const root = await mkdtemp(join(tmpdir(), "launch-preflight-")); const project = join(root, "project"); await mkdir(project);
  const fd = await open(project, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try {
    await writeFile(join(project, "normal"), "normal"); await scanWritableRoot(fd, project);
    await expect(scanWritableRoot(fd, project, 0)).rejects.toThrow("bounds");
    await expect(scanWritableRoot(fd, project, 100, -1)).rejects.toThrow("elapsed");
    await writeFile(join(root, "outside"), "untouched"); await link(join(root, "outside"), join(project, "alias"));
    await expect(scanWritableRoot(fd, project)).rejects.toThrow("hardlinked");
    expect(await readFile(join(root, "outside"), "utf8")).toBe("untouched");
    await rm(join(project, "alias"));
    execFileSync("/usr/bin/mkfifo", [join(project, "fifo")]);
    await expect(scanWritableRoot(fd, project)).rejects.toThrow("FIFO"); await rm(join(project, "fifo"));
    const hidden = join(project, "hidden"); await mkdir(hidden); await chmod(hidden, 0);
    if (process.getuid?.() !== 0) await expect(scanWritableRoot(fd, project)).rejects.toThrow("inaccessible");
    await chmod(hidden, 0o700);
  } finally { await fd.close(); await rm(root, { recursive: true, force: true }); }
});

test("real namespace nested same-filesystem bind mount is rejected from mountinfo", async () => {
  const root = await mkdtemp(join(tmpdir(), "launch-nested-mount-")); await mkdir(join(root, "nested"));
  try {
    const script = `import { open } from 'node:fs/promises'; import { scanWritableRoot } from '/preflight.mjs'; const f = await open('/workspace', 'r'); try { await scanWritableRoot(f, '/workspace'); process.exitCode=1; } catch(e) { if(!e.message.includes('nested mount')) process.exitCode=2; } finally { await f.close(); }`;
    const child = spawn("/bin/bwrap", ["--unshare-user", "--unshare-pid", "--proc", "/proc", "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "--ro-bind", process.execPath, process.execPath, "--ro-bind", resolve("dist/session/launch_preflight.js"), "/preflight.mjs", "--ro-bind", root, "/workspace", "--ro-bind", root, "/workspace/nested", "--", process.execPath, "--input-type=module", "-e", script], { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = ""; child.stderr.on("data", b => { stderr += b; });
    const code = await new Promise<number | null>((ok, fail) => { child.once("exit", ok); child.once("error", fail); });
    expect(code, stderr).toBe(0);
  } finally { await rm(root, { recursive: true, force: true }); }
}, 10000);
