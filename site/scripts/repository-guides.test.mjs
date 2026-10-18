import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { GUIDES, guideUrl, repositoryUrl } from "../src/lib/repository-guides.mjs";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(site, "..");
const source = (path) => readFileSync(join(site, "src", path), "utf8");

function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? files(join(dir, entry.name)) : [join(dir, entry.name)]);
}

test("repository config is explicit and rejects ambiguous/untrusted URLs", () => {
  for (const value of [undefined, null, "", " ", "http://github.com/a/b", "https://gitlab.com/a/b",
    "https://github.com.evil.test/a/b", "https://github.com@evil.test/a/b", "https://user@github.com/a/b",
    "https://user:secret@github.com/a/b", "https://github.com:443/a/b", "https://github.com/a/b?x=1",
    "https://github.com/a/b?", "https://github.com/a/b#guide", "https://github.com/a/b#",
    "https://github.com/a/b/tree/main", "https://github.com/a", "//github.com/a/b",
    "https://github.com/a/..", "https://github.com/a/.", "https://github.com/a/b.git",
    "https://github.com/a/%2e%2e", "https://github.com/a/b\n", " https://github.com/a/b",
    "https://github.com/a/b\\evil", "https://github.com/a/b//"]) {
    assert.equal(repositoryUrl(value), null, String(value));
    assert.equal(guideUrl(value, GUIDES.index.path), null, String(value));
  }
  assert.equal(repositoryUrl("https://github.com/owned-project/source_repo/"), "https://github.com/owned-project/source_repo");
  assert.equal(guideUrl("https://github.com/owner/repo", "../../evil"), null);
});

test("every canonical target exists, anchors resolve and links stay in configured repository", () => {
  for (const { path } of Object.values(GUIDES)) {
    const [file, anchor] = path.split("#");
    assert.ok(existsSync(join(root, file)), path);
    if (anchor) {
      const headings = readFileSync(join(root, file), "utf8").split("\n")
        .filter((line) => /^#+ /.test(line))
        .map((line) => line.replace(/^#+ /, "").toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/ /g, "-"));
      assert.ok(headings.includes(anchor), path);
    }
    assert.equal(guideUrl("https://github.com/owned/source/", path), `https://github.com/owned/source/blob/HEAD/${path}`);
  }
});

test("legacy docs and tutorial routes remain thin canonical guide entry points", () => {
  const paths = ["docs/page.tsx", "remote-pi/docs/page.tsx", "download/page.tsx", "remote-pi/download/page.tsx"];
  for (const prefix of ["remote-pi/tutorials", "tutorials"]) {
    for (const file of files(join(site, "src/app", prefix))) {
      if (file.endsWith("/page.tsx") && dirname(file) !== join(site, "src/app", prefix)) paths.push(file.slice(join(site, "src/app").length + 1));
    }
  }
  assert.equal(paths.length, 12);
  for (const path of paths) {
    const text = source(`app/${path}`);
    assert.match(text, /<GuidePage/);
    assert.doesNotMatch(text, /CodeBlock|DocsTable|https:\/\//);
    assert.ok(text.length < 1400, path);
    const keys = JSON.parse(text.match(/guides=\{(\[[^\]]+\])\}/)[1]);
    for (const key of keys) assert.ok(GUIDES[key], `${path}: ${key}`);
  }
});

test("rendered source offers no unsupported registry or remote-script installs", () => {
  for (const file of files(join(site, "src"))) {
    if (!/\.(tsx?|mjs)$/.test(file)) continue;
    const text = readFileSync(file, "utf8");
    assert.doesNotMatch(text, /npm:remote-pi|npm\s+(?:install|i)\s+(?:-g|--global)\s+remote-pi|curl\s+[^\n]*(?:install|cockpit-server)\.sh/i, file);
  }
  assert.match(source("components/repository-guides.tsx"), /process\.env\.NEXT_PUBLIC_REPOSITORY_URL/);
  assert.match(source("components/repository-guides.tsx"), /aria-disabled="true"/);
  assert.match(source("components/repository-guides.tsx"), /Repository guides unavailable/);
  assert.match(source("components/legal-shell.tsx"), /Upstream reference only/);
  assert.match(source("components/footer.tsx"), /©.*new Date/s);
});
