// Source-only distribution: no manifest fetch, publisher default or mock assets.
export type CockpitPlatform = "macos" | "windows" | "linux" | "android";
export type CockpitArch = "universal" | "x64" | "arm64";
export type CockpitFormat = "dmg" | "exe" | "deb" | "rpm" | "apk" | "aab";

/** Artifact shape retained for download UI types; feeds are disabled. */
export type CockpitArtifact = {
  platform: CockpitPlatform;
  arch: CockpitArch;
  format: CockpitFormat;
  url: string;
  sha256: string;
  size: number;
};

export type CockpitManifest = {
  version: string;
  date: string;
  notes: string;
  artifacts: CockpitArtifact[];
};

export type ManifestLoad = { manifest: CockpitManifest; live: boolean };

export async function loadCockpitManifest(): Promise<ManifestLoad> {
  return {
    manifest: { version: "", date: "", notes: "Binary downloads disabled. Build from source.", artifacts: [] },
    live: false,
  };
}

/**
 * Last path segment of an artifact URL, e.g. `remote-pi-cockpit_1.0.0_amd64.deb`.
 * Structurally typed so the app manifest (plan/44) reuses it without importing
 * cockpit's format/platform unions.
 */
export function artifactFileName(a: { url: string; format: string }): string {
  const seg = a.url.split("/").pop();
  return seg && seg.length > 0 ? seg : `cockpit.${a.format}`;
}

/** Human-readable file size from a byte count. */
export function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return "—";
  const mb = bytes / (1024 * 1024);
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${mb.toFixed(1)} MB`;
}

/** Display label for an architecture, in the download card. */
export const ARCH_LABEL: Record<CockpitArch, string> = {
  universal: "Universal · Apple Silicon + Intel",
  x64: "x86_64 / amd64",
  arm64: "arm64 / aarch64",
};
