import { test, expect, vi } from "vitest";
import { mkdtemp, mkdir, writeFile, symlink, chmod, rm, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { launchSandbox } from "./launch_sandbox.js";
import { LaunchRegistry } from "./launch_store.js";
import { LaunchPreflightError } from "./launch_preflight.js";

test.each(["symlink-settings", "malformed", "array", "provider", "model", "bounds", "world-write", "unsafe-symlink-target", "directory", "protected-settings", "auth-symlink", "auth-mode", "auth-malformed", "auth-bounds", "auth-missing", "dangling-settings"])("fixed host model files: %s", async kind => {
  const root = await mkdtemp(join(tmpdir(), "launch-model-files-"));
  const project = join(root, "project"), agent = join(root, "agent");
  await mkdir(project); await mkdir(agent);
  const auth = join(agent, "auth.json"), settings = join(agent, "settings.json");
  await writeFile(auth, JSON.stringify({ openai: { type: "api_key", key: "synthetic-only" } }), { mode: 0o600 });
  vi.stubEnv("PI_CODING_AGENT_DIR", agent);
  try {
    if (kind === "symlink-settings") {
      const final = join(root, "public-settings");
      await writeFile(final, JSON.stringify({ defaultProvider: "openai", defaultModel: "gpt-4o-mini", resources: ["must-not-copy"] }));
      await chmod(final, 0o664); await symlink(final, settings);
    } else if (kind === "dangling-settings") {
      await symlink(join(root, "missing"), settings);
    } else if (kind === "unsafe-symlink-target") {
      const target = join(root, "unsafe-target"); await writeFile(target, "{}"); await chmod(target, 0o666); await symlink(target, settings);
    } else if (kind === "protected-settings") {
      const target = join(project, "settings.json"); await writeFile(target, "{}"); await symlink(target, settings);
    } else if (kind.startsWith("auth-")) {
      if (kind === "auth-symlink") { await rm(auth); await writeFile(join(root, "target"), "{}", { mode: 0o600 }); await symlink(join(root, "target"), auth); }
      if (kind === "auth-missing") await rm(auth);
      if (kind === "auth-mode") await chmod(auth, 0o664);
      if (kind === "auth-malformed") await writeFile(auth, "secret-invalid-json");
      if (kind === "auth-bounds") await writeFile(auth, " ".repeat(131073));
    } else if (kind === "directory") await mkdir(settings);
    else {
      const content: Record<string, string> = { malformed: "secret-invalid-json", array: "[]", provider: '{"defaultProvider":7}', model: '{"defaultModel":"bad\\u0000model"}', bounds: " ".repeat(131073), "world-write": "{}" };
      await writeFile(settings, content[kind]!);
      if (kind === "world-write") await chmod(settings, 0o666);
    }
    const registry = new LaunchRegistry(join(root, "store"));
    const entry = await registry.add("fixture", project, [project]);
    if (kind === "symlink-settings") {
      const plan = await launchSandbox(entry, resolve("dist/index.js"), [], "fixture");
      await plan.close();
      expect((await stat(join(root, "public-settings"))).mode & 0o777).toBe(0o664);
    } else {
      const error = await launchSandbox(entry, resolve("dist/index.js"), [], "fixture").catch(e => e);
      expect(error).toBeInstanceOf(LaunchPreflightError);
      expect(error.message).toBe(kind === "protected-settings" ? "Registered project overlaps protected runtime or Pi configuration; register a separate project locally" : kind.startsWith("auth-") ? "Inspect local Pi auth.json: use a regular user-owned private 0600 file with valid stored credentials; symlinks are not supported" : "Inspect local Pi settings.json: use valid model defaults in a bounded user-owned regular file (symlinks to safe files are supported)");
      expect(error.message).not.toContain(root);
    }
  } finally { vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true }); }
});

test("missing installed runtime is a safe actionable preflight failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "launch-runtime-missing-"));
  try {
    const project = join(root, "project"); await mkdir(project);
    const registry = new LaunchRegistry(join(root, "store"));
    const entry = await registry.add("fixture", project, [project]);
    await expect(launchSandbox(entry, join(root, "missing-release", "dist", "index.js"), [], "fixture")).rejects.toThrow("Prepare the private Pi 1.3.0 managed runtime locally with scripts/prepare-managed-runtime.mjs; inspect its ownership, integrity and bounded closure");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test.each(["absent", "provider-only", "model-only", "unknown", "custom-api"])("configured defaults fail closed: %s", async kind => {
  const root = await mkdtemp(join(tmpdir(), "model-selection-"));
  const project = join(root, "project"), agent = join(root, "agent");
  await mkdir(project); await mkdir(agent);
  await writeFile(join(agent, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: "synthetic", refresh: "synthetic" } }), { mode: 0o600 });
  const defaults = { defaultProvider: "openai-codex", defaultModel: kind === "unknown" ? "not-a-real-model" : "gpt-6.1-sol" };
  if (kind !== "absent") await writeFile(join(agent, "settings.json"), JSON.stringify(kind === "provider-only" ? { defaultProvider: defaults.defaultProvider } : kind === "model-only" ? { defaultModel: defaults.defaultModel } : defaults));
  if (kind === "custom-api") await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "openai-codex": { api: "unsupported-custom-api", apiKey: "!must-not-run" } } }));
  vi.stubEnv("PI_CODING_AGENT_DIR", agent);
  try {
    const entry = await new LaunchRegistry(join(root, "store")).add("fixture", project, [project]);
    await expect(launchSandbox(entry, resolve("dist/index.js"), [], "fixture")).rejects.toThrow(kind === "unknown" ? "Configured default is not a supported bundled model" : kind === "custom-api" ? "Custom model configuration cannot be inherited securely" : "Configure both defaultProvider and defaultModel");
  } finally { vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true }); }
});
