// Loaded only by host_boundary.test.ts through the real Pi extension loader.
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { SettingsManager, convertToPng, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Box, Container, Image, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { Compile } from "typebox/compile";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import host from "../../host/index.js";
import { findRemotePiScript, findSupervisorScript } from "../../src/daemon/install.js";
import { registerAgentTools } from "../../src/session/tools.js";

export default async function (pi: ExtensionAPI) {
  // The test preload imports the *same native virtual-module table* used by
  // this bundled Pi loader, rather than a second unbundled SDK facade.
  const owned = (globalThis as unknown as Record<symbol, Record<string, Record<string, unknown>>>)[Symbol.for("remote-pi.test.host-exports")];
  assert(owned);
  assert.equal(SettingsManager, owned["@earendil-works/pi-coding-agent"].SettingsManager);
  assert.equal(convertToPng, owned["@earendil-works/pi-coding-agent"].convertToPng);
  for (const [name, value] of Object.entries({ Box, Container, Image, Text })) assert.equal(value, owned["@earendil-works/pi-tui"][name]);
  assert.equal(Type, owned.typebox.Type);
  assert.equal(Compile, owned["typebox/compile"].Compile);
  const root = fileURLToPath(new URL("../../", import.meta.url));
  assert.equal(findSupervisorScript(), join(root, "dist/bin/supervisord.js"));
  assert.equal(findRemotePiScript(), join(root, "dist/index.js"));
  assert(existsSync(findSupervisorScript()));
  assert(existsSync(findRemotePiScript()));
  // Exercise public APIs supplied by the host, not physical standalone copies.
  const settings = SettingsManager.create(process.cwd());
  assert.equal(settings.getDefaultProvider(), "fixture-provider");
  assert.equal(settings.getDefaultModel(), "fixture-model");
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
  assert.deepEqual(await convertToPng(png, "image/png"), { data: png, mimeType: "image/png" });
  assert.equal(await convertToPng("", "image/jpeg"), null);
  const container = new Container();
  const box = new Box(1, 1);
  box.addChild(new Text("host rendering"));
  container.addChild(box);
  assert(container.render(40).join("\n").includes("host rendering"));
  assert(new Image(png, "image/png", { fallbackColor: (s) => s }).render(40).length > 0);
  const schema = Type.Object({ to: Type.String() });
  assert(Compile(schema).Check({ to: "peer" }));
  assert(!Compile(schema).Check({ to: 42 }));
  const registered: string[] = [];
  // Source tool schemas must be accepted by the host TypeBox compiler too.
  registerAgentTools({ registerTool(tool) {
    assert(Compile(tool.parameters).Check(tool.name === "list_peers" ? {} : { to: "peer", body: "test" }));
    registered.push(tool.name);
  } } as ExtensionAPI, () => null);
  assert(registered.includes("agent_send"));
  assert.equal(typeof host, "function");
  let lifecycleCount = 0;
  pi.on("session_start", () => {
    lifecycleCount++;
    const names = pi.getAllTools().map(tool => tool.name);
    for (const name of registered) assert.equal(names.filter(n => n === name).length, 1);
    writeFileSync(process.env.REMOTE_PI_HOST_PROOF!, JSON.stringify({ apis: true, identity: true, builtResolvers: true, lifecycleCount, registered }));
  });
}
