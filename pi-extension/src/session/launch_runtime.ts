import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import { LaunchPreflightError } from "./launch_preflight.js";

const ERROR = "Prepare the private Pi 1.3.0 managed runtime locally with scripts/prepare-managed-runtime.mjs; inspect its ownership, integrity and bounded closure";
export type ExpectedModel = { provider: string; id: string; api: string; contextWindow: number; maxTokens: number; compat?: unknown; thinkingLevelMap?: unknown; reasoning?: boolean; input?: unknown };
/** Snapshot path is derived from the trusted installed extension, never a request.
 * Validate all content, including assets and directory entries, before mounting. */
export async function managedRuntime(extensionRoot: string): Promise<{ root: string; cli: string; catalog(provider: string, id: string): ExpectedModel }> {
  const root = resolve(extensionRoot, "build/managed-runtime");
  try {
    if (await realpath(root) !== root) throw new Error();
    const files = new Map<string, Buffer>();
    let count = 0, bytes = 0;
    const deadline = Date.now() + 5000;
    const walk = async (path: string, relative: string): Promise<void> => {
      const s = await lstat(path);
      if (++count > 15000 || Date.now() > deadline || s.uid !== process.getuid?.() || (s.mode & 0o222) || s.isSymbolicLink()) throw new Error();
      if (s.isDirectory()) { for (const entry of await readdir(path)) await walk(join(path, entry), relative ? relative + "/" + entry : entry); }
      else if (s.isFile() && s.nlink === 1 && s.size <= 32 * 1024 * 1024 && (bytes += s.size) <= 160 * 1024 * 1024) {
        const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
          const pinned = await fd.stat();
          if (!pinned.isFile() || pinned.dev !== s.dev || pinned.ino !== s.ino || pinned.size !== s.size || pinned.uid !== s.uid || pinned.mode !== s.mode || pinned.nlink !== 1) throw new Error();
          const data = Buffer.alloc(s.size + 1);
          let length = 0;
          while (length < data.length) {
            const read = await fd.read(data, length, data.length - length, null);
            if (!read.bytesRead) break;
            length += read.bytesRead;
            if (Date.now() > deadline) throw new Error();
          }
          if (length !== s.size) throw new Error();
          files.set(relative, data.subarray(0, length));
        } finally { await fd.close(); }
      }
      else throw new Error();
    };
    await walk(root, "");
    const manifest = JSON.parse(files.get("manifest.json")!.toString()) as { version: number; piVersion: string; files: Record<string, string> };
    if (manifest.version !== 1 || manifest.piVersion !== "1.3.0" || Object.keys(manifest.files).length !== files.size - 1) throw new Error();
    for (const [path, hash] of Object.entries(manifest.files)) if (!files.has(path) || createHash("sha256").update(files.get(path)!).digest("hex") !== hash) throw new Error();
    for (const [name, version] of Object.entries({ "@earendil-works/pi-coding-agent": "1.3.0", typebox: "1.3.27", undici: "8.10.2", jiti: "2.7.0", "@silvia-odwyer/photon-node": "0.3.4" })) {
      const pkg = JSON.parse(files.get(`node_modules/${name}/package.json`)!.toString()) as { name: string; version: string };
      if (pkg.name !== name || pkg.version !== version) throw new Error();
    }
    const cli = join(root, "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
    if (!files.has("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")) throw new Error();
    return { root, cli, catalog(provider, id) {
      try {
        const data = JSON.parse(files.get(`catalog/${provider}.json`)!.toString()) as Record<string, Record<string, ExpectedModel>>;
        const models = Object.values(data).flatMap(group => Object.values(group));
        const model = models.find(m => m.provider === provider && m.id === id);
        if (!model || typeof model.api !== "string" || !model.contextWindow || !model.maxTokens) throw new Error();
        return model;
      } catch { throw new LaunchPreflightError("Configured default is not a supported bundled model; configure an exact built-in provider/model locally (custom providers and overrides are not copied)"); }
    } };
  } catch { throw new LaunchPreflightError(ERROR); }
}
