import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { siteUrl } from "../src/lib/site-url.mjs";
import { repositoryUrl } from "../src/lib/repository-guides.mjs";

// Run after pnpm build, with the same NEXT_PUBLIC_REPOSITORY_URL used to build.
const output = resolve(dirname(fileURLToPath(import.meta.url)), "../.next/server/app");
const repository = repositoryUrl(process.env.NEXT_PUBLIC_REPOSITORY_URL);
const routes = ["download", "remote-pi/download", "docs", "remote-pi/docs", "remote-pi/tutorials/getting-started",
  "remote-pi/tutorials/mesh-local", "remote-pi/tutorials/mesh-remote",
  "remote-pi/tutorials/daemon", "remote-pi/tutorials/claude-mesh",
  "tutorials/cockpit-layouts", "tutorials/cockpit-team", "tutorials/cockpit-telemetry"];

for (const route of routes) {
  test(`prerendered canonical navigation: /${route}`, () => {
    const html = readFileSync(resolve(output, `${route}.html`), "utf8");
    // Only visible HTML, not RSC hydration data.
    const visible = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
    const links = [...visible.matchAll(/href="([^"]*\/blob\/[^\"]*)"/g)].map((m) => m[1]);
    assert.doesNotMatch(visible, /npm:remote-pi|npm install -g remote-pi|curl -fsSL/);
    assert.match(visible, /License: MIT/);
    if (repository) {
      assert.ok(links.length > 0);
      for (const href of links) assert.ok(href.startsWith(`${repository}/blob/HEAD/`), href);
      assert.doesNotMatch(visible, /Repository guides unavailable|aria-disabled="true"/);
    } else {
      assert.equal(links.length, 0);
      assert.match(visible, /Repository guides unavailable/);
      assert.match(visible, /role="link" aria-disabled="true"/);
    }
  });
}

test("retained legal reference prominently distinguishes upstream operator", () => {
  for (const route of ["terms", "privacy"]) {
    const html = readFileSync(resolve(output, `${route}.html`), "utf8");
    assert.match(html, /Upstream reference only/);
    assert.match(html, /original Flutterando service/);
    assert.match(html, /33\.637\.582\/0001-70/);
  }
});


test("rendered landings and downloads have no implicit operational publisher", () => {
  const origin = siteUrl(process.env.NEXT_PUBLIC_SITE_URL);
  for (const route of ["index", "remote-pi", "download", "remote-pi/download", "docs"]) {
    const html = readFileSync(resolve(output, `${route}.html`), "utf8");
    const visible = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
    assert.doesNotMatch(visible, /jacobaraujo7|jacobmoura\.work|apps\.apple\.com|play\.google\.com|raw\.githubusercontent/);
    assert.doesNotMatch(visible, /href="[^"]+\.(?:apk|exe|dmg|deb|rpm|sh)(?:[?"])/);
    const source = [...visible.matchAll(/<a[^>]*href="(https:\/\/github\.com\/[^"]+)"/g)].map((match) => match[1]);
    if (repository) {
      assert.ok(source.includes(repository), route);
      for (const href of source) assert.ok(href === repository || href.startsWith(`${repository}/blob/HEAD/`), href);
    } else {
      assert.equal(source.length, 0, route);
      assert.match(visible, /Source unavailable: configure NEXT_PUBLIC_REPOSITORY_URL/);
    }
    const ogUrl = visible.match(/<meta property="og:url" content="([^"]+)"/);
    if (origin) assert.ok(ogUrl?.[1].startsWith(origin), route);
    else assert.equal(ogUrl, null, route);
  }
});

test("built redirect table contains only internal navigation", () => {
  const manifest = JSON.parse(readFileSync(resolve(output, "../../routes-manifest.json"), "utf8"));
  for (const redirect of manifest.redirects) {
    assert.ok(redirect.destination.startsWith("/") && !redirect.destination.startsWith("//"), redirect.destination);
  }
  assert.ok(!manifest.redirects.some((redirect) => redirect.source === "/cockpit-server.sh"));
});
