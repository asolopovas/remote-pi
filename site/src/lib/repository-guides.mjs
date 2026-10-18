/** Explicit deployment configuration only: never infer a publisher. */
export function repositoryUrl(value) {
  if (typeof value !== "string" || value !== value.trim() || !/^https:\/\/github\.com\/[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\/[A-Za-z0-9_.-]+\/?$/.test(value)) return null;
  const repo = value.split("/")[4];
  if (repo === "." || repo === ".." || repo.endsWith(".git")) return null;
  return value.replace(/\/$/, "");
}

// GitHub HEAD follows the configured repository's default branch, not upstream main.
export function guideUrl(repository, path) {
  const base = repositoryUrl(repository);
  if (!base || !Object.values(GUIDES).some((guide) => guide.path === path)) return null;
  return `${base}/blob/HEAD/${path}`;
}

export const GUIDES = {
  index: { label: "Project map", path: "README.md#project-map" },
  extension: { label: "Host extension — source build and setup", path: "pi-extension/README.md#build-and-install-this-source" },
  mobile: { label: "Mobile client — build and pairing", path: "app/README.md" },
  relay: { label: "Relay — self-hosting", path: "relay/README.md" },
  messaging: { label: "Agent messaging and mesh", path: "pi-extension/skills/agent-network/SKILL.md" },
  daemon: { label: "Daemon operations", path: "pi-extension/docs/daemon.md" },
  launch: { label: "Phone project launch", path: "SECURE-LAUNCH.md" },
  protocol: { label: "Protocol and trust model", path: "PROTOCOL.md" },
  security: { label: "Security and publication gates", path: "SECURITY.md" },
  cockpit: { label: "Cockpit — source build and project guide", path: "cockpit/README.md" },
  remote: { label: "Cockpit — remote host setup", path: "cockpit/README.md#remote-host" },
  cli: { label: "Cockpit CLI and automation", path: "cockpit/cli/text/skill.md" },
  layouts: { label: "Cockpit layouts", path: "cockpit/docs/layout-ckp.md" },
  tasks: { label: "Cockpit tasks", path: "cockpit/docs/tasks-json.md" },
  telemetry: { label: "Cockpit telemetry", path: "cockpit/docs/telemetry.md" },
  themes: { label: "Cockpit themes", path: "cockpit/docs/theme-format.md" },
  notebooks: { label: "Cockpit notebooks", path: "cockpit/docs/notebook.md" },
  hooks: { label: "Agent status hooks", path: "cockpit/docs/turn-status-hooks.md" },
};
