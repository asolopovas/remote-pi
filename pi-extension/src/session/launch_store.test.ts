import { test, expect } from "vitest";
import { mkdtemp, mkdir, rename, rm, symlink, chmod, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { LaunchRegistry, identifyFolder, readPrivateJson } from "./launch_store.js";

test("local registered exact projects, explicit allowed cwd, no enumeration and restrictive atomic registry", async () => {
  const root = await mkdtemp(join(tmpdir(), "launch-store-")); const cwd = join(root, "project"); await mkdir(cwd);
  const dir = join(root, "store"); const registry = new LaunchRegistry(dir);
  try {
    await expect(registry.list()).rejects.toThrow();
    await expect(registry.add("missing-allow", cwd, [])).rejects.toThrow();
    await expect(registry.add("outside-cwd", cwd, [join(root, "store")])).rejects.toThrow();
    for (const path of ["relative", "/", process.env.HOME!, cwd + "/../project"]) await expect(identifyFolder(path)).rejects.toThrow();
    const link = join(root, "link"); await symlink(cwd, link); await expect(identifyFolder(link)).rejects.toThrow();
    const [first, second] = await Promise.all([registry.add("one", cwd, [cwd]), registry.add("two", cwd, [cwd])]);
    expect((await registry.list()).map(p => p.id).sort()).toEqual([first.id, second.id].sort());
    await Promise.all([registry.remove(first.id), registry.add("three", cwd, [cwd])]);
    expect((await registry.list()).map(p => p.name).sort()).toEqual(["three", "two"]);
    await rename(cwd, cwd + "-old"); await mkdir(cwd);
    await expect(registry.list()).rejects.toThrow("replaced");
    await registry.remove(second.id); // local removal can recover stale entries
    await chmod(join(dir, "projects.json"), 0o644);
    await expect(readPrivateJson(dir, "projects.json")).rejects.toThrow("Unsafe");
    await chmod(join(dir, "projects.json"), 0o600);
    await writeFile(join(dir, "projects.json"), "malformed");
    await expect(registry.add("must-not-reset", cwd, [cwd])).rejects.toThrow();
  } finally { await rm(root, { recursive: true, force: true }); }
});
