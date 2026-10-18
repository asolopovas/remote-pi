// Source-only distribution: no manifest fetch, publisher default or mock assets.
export type AppPlatform = "android";
export type AppArch = "universal";
export type AppFormat = "apk";

/** Artifact shape retained for UI types; feeds are disabled. */
export type AppArtifact = {
  platform: AppPlatform;
  arch: AppArch;
  format: AppFormat;
  url: string;
  sha256: string;
  size: number;
};

export type AppManifest = {
  version: string;
  date: string;
  notes: string;
  artifacts: AppArtifact[];
};

export type AppManifestLoad = { manifest: AppManifest; live: boolean };

export async function loadAppManifest(): Promise<AppManifestLoad> {
  return {
    manifest: { version: "", date: "", notes: "Binary downloads disabled. Build from source.", artifacts: [] },
    live: false,
  };
}
