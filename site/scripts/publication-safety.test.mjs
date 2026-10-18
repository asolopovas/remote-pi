// Node 22: node --experimental-strip-types --test scripts/publication-safety.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { siteUrl } from "../src/lib/site-url.mjs";
import { loadAppManifest } from "../src/lib/app-release.ts";
import { loadCockpitManifest } from "../src/lib/cockpit-release.ts";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(site, path), "utf8");
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? files(join(dir, entry.name)) : [join(dir, entry.name)]);
}

test("metadata requires an explicit HTTPS origin without credentials or suffixes", () => {
  for (const value of [undefined, "", "http://owned.example", "//owned.example", "https://user:secret@owned.example",
    "https://@owned.example", "https://owned.example?", "https://owned.example#", "https://owned.example/path",
    "https://owned.example\\other", "https://owned.example/../", "https://own\ned.example", " https://owned.example", "https://owned.example\n", "not a URL"]) {
    assert.equal(siteUrl(value), undefined, String(value));
  }
  assert.equal(siteUrl("https://owned.example/"), "https://owned.example");
  assert.equal(siteUrl("https://owned.example:8443"), "https://owned.example:8443");
});

test("obsolete feed configuration cannot fetch or offer executable artifacts", async () => {
  const previousFetch = globalThis.fetch;
  const previousApp = process.env.NEXT_PUBLIC_APP_MANIFEST_URL;
  const previousCockpit = process.env.NEXT_PUBLIC_COCKPIT_MANIFEST_URL;
  let requests = 0;
  globalThis.fetch = async () => { requests++; throw new Error("Network forbidden"); };
  try {
    for (const value of [undefined, "invalid", "https://unowned.example/latest.json"]) {
      for (const key of ["NEXT_PUBLIC_APP_MANIFEST_URL", "NEXT_PUBLIC_COCKPIT_MANIFEST_URL"]) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
      for (const load of [loadAppManifest, loadCockpitManifest]) {
        const result = await load();
        assert.equal(result.live, false);
        assert.deepEqual(result.manifest.artifacts, []);
      }
    }
    assert.equal(requests, 0);
  } finally {
    globalThis.fetch = previousFetch;
    for (const [key, value] of [["NEXT_PUBLIC_APP_MANIFEST_URL", previousApp], ["NEXT_PUBLIC_COCKPIT_MANIFEST_URL", previousCockpit]]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});

test("public installer endpoints remain inert after the build synchronization step", () => {
  const before = ["install.sh", "cockpit-server.sh"].map((name) => read(`public/${name}`));
  const sync = spawnSync(process.execPath, [join(site, "scripts/sync-install-sh.mjs")], { encoding: "utf8" });
  assert.equal(sync.status, 0, sync.stderr);
  for (const [index, name] of ["install.sh", "cockpit-server.sh"].entries()) {
    const script = read(`public/${name}`);
    assert.equal(script, before[index]);
    assert.doesNotMatch(script, /https?:|curl|wget|npm|systemctl|launchctl/);
    // Only shell builtins work: an accidental downloader cannot run via PATH.
    const run = spawnSync("/bin/sh", [join(site, "public", name)], { encoding: "utf8", env: { PATH: "/nonexistent" } });
    assert.equal(run.status, 1);
    assert.equal(run.stdout, "");
    assert.match(run.stderr, /Installer disabled.*source-only/);
  }
  assert.doesNotMatch(read("next.config.ts"), /https?:|raw\.githubusercontent/);
});

test("source CTAs use the validated helper; external literals are attribution only", () => {
  assert.match(read("src/components/source-link.tsx"), /repositoryUrl\(process\.env\.NEXT_PUBLIC_REPOSITORY_URL\)/);
  assert.match(read("src/components/source-link.tsx"), /aria-disabled="true"/);
  for (const file of files(join(site, "src"))) {
    if (!/\.(tsx?|mjs)$/.test(file)) continue;
    const text = readFileSync(file, "utf8");
    assert.doesNotMatch(text, /jacobaraujo7|jacobmoura\.work|apps\.apple\.com|play\.google\.com|raw\.githubusercontent/);
    for (const match of text.matchAll(/https?:\/\/[^\s"'<>`)]+/g)) {
      assert.ok(["https://github.com/asolopovas", "https://flutterando.com.br", "https://github.com/owner/repo"].includes(match[0]), `${file}: ${match[0]}`);
    }
  }
});
