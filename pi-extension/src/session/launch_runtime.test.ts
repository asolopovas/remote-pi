import { test, expect, vi } from "vitest";
import { mkdtemp, mkdir, cp, rm, chmod, readdir, writeFile, symlink, unlink, readFile, truncate } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { managedRuntime } from "./launch_runtime.js";

async function unseal(p: string): Promise<void> { await chmod(p, 0o700); for (const e of await readdir(p, { withFileTypes: true })) if (e.isDirectory()) await unseal(join(p, e.name)); }
test("private runtime validates selected closure, rejects mutation, missing dependencies, permissions and symlink roots", async () => {
  const root = await mkdtemp(join(tmpdir(), "runtime-integrity-"));
  const runtime = join(root, "build/managed-runtime");
  await mkdir(join(root, "build"));
  await cp(resolve("build/managed-runtime"), runtime, { recursive: true });
  const catalog = join(runtime, "catalog/openai-codex.json");
  try {
    const valid = await managedRuntime(root);
    expect(valid.catalog("openai-codex", "gpt-6.1-sol")).toMatchObject({ api: "openai-codex-responses", contextWindow: 500000 });
    expect(() => valid.catalog("openai-codex", "nonexistent")).toThrow("Configured default is not a supported bundled model");
    const actualUid = process.getuid!();
    const owner = vi.spyOn(process, "getuid").mockReturnValue(actualUid + 1);
    try { await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure"); } finally { owner.mockRestore(); }
    await chmod(catalog, 0o600);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
    await chmod(catalog, 0o400);
    const original = await readFile(catalog);
    await chmod(catalog, 0o600); await writeFile(catalog, "{}"); await chmod(catalog, 0o400);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
    await chmod(catalog, 0o600); await truncate(catalog, 32 * 1024 * 1024 + 1); await chmod(catalog, 0o400);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
    await chmod(catalog, 0o600); await writeFile(catalog, original); await chmod(catalog, 0o400);
    const parent = join(runtime, "node_modules/jiti");
    await chmod(parent, 0o700); await unlink(join(parent, "package.json")); await chmod(parent, 0o500);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
    await unseal(runtime); await rm(runtime, { recursive: true });
    await symlink(resolve("build/managed-runtime"), runtime);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
    await unlink(runtime);
    await mkdir(runtime, { mode: 0o700 });
    await writeFile(join(runtime, "manifest.json"), "{}", { mode: 0o400 }); await chmod(runtime, 0o500);
    await expect(managedRuntime(root)).rejects.toThrow("ownership, integrity and bounded closure");
  } finally { await unseal(root); await rm(root, { recursive: true, force: true }); }
});
