# Remote Pi

Control a local [Pi coding agent](https://github.com/earendil-works/pi) from a phone, connect agents through a local/cross-PC mesh, or use the Cockpit terminal workspace.

Maintainer and author of contributions: **Andrius Solopovas**.
Derived from [Remote Pi by Jacob Moura](https://github.com/jacobaraujo7/remote_pi).

## Source checkout

The canonical repository is [asolopovas/remote-pi](https://github.com/asolopovas/remote-pi), on `main`. All projects below live in this single monorepo; no separate clones or Git submodules are required.

```sh
git clone https://github.com/asolopovas/remote-pi.git
cd remote-pi
```

## Project map

Each guide owns its project's prerequisites, build/run commands, configuration and maintenance. Run commands from the directory named in that guide.

| Project | Location and guide | Responsibility |
|---|---|---|
| Host extension | [pi-extension/](pi-extension/README.md) | Pi integration, local broker, relay client and managed agents |
| Relay | [relay/](relay/README.md) | WebSocket routing, presence and signed membership storage |
| Mobile client | [app/](app/README.md) | Android/iOS pairing, chat and remote controls |
| Cockpit | [cockpit/](cockpit/README.md) | Terminal workspace, CLI and [shared packages/headless server](cockpit/README.md#package-map) |
| Website | [site/](site/README.md) | Product pages and canonical source-guide links; binary delivery disabled |
| Download server | [rp-s3/](rp-s3/README.md) | Release files and update-manifest hosting |

## How the projects connect

- **Phone control:** the [mobile client](app/README.md#connect-and-use) and [host extension](pi-extension/README.md#build-and-install-this-source) connect through the same [relay](relay/README.md#self-host-with-docker). Start with those guides, then pair the client. Local-only agent messaging does not require the relay.
- **Terminal workspaces:** [Cockpit](cockpit/README.md#remote-host) connects to its headless server over SSH. This is separate from the mobile/extension relay protocol; running Pi inside a Cockpit terminal is optional.
- **Distribution:** [local release packaging](cockpit/packaging/README.md) and [mobile build instructions](app/README.md#build-and-run) produce artifacts. The [website](site/README.md#integrations) currently links to source guides only; [download-server manifests](rp-s3/README.md#integrations) are optional future distribution, not an active feed. Neither service is required for a local source build.
- **Shared presentation:** [branding/](branding/README.md) holds source artwork used by the clients, website and package metadata.

## Documentation ownership

Use these canonical references instead of copying their details into another project:

| Topic | Reference |
|---|---|
| Mobile/extension/relay wire format, identity, pairing and trust model | [PROTOCOL.md](PROTOCOL.md) |
| Phone project-launch workflow | [SECURE-LAUNCH.md](SECURE-LAUNCH.md) |
| Host launch configuration, authority and sandbox contract | [Launcher contract](pi-extension/docs/secure-launcher.md) |
| Exact-session stop and display metadata | [Session controls](pi-extension/docs/session-control.md), [room display](pi-extension/docs/room-display-endpoint.md) |
| Agent messaging and asynchronous replies | [Agent-network skill](pi-extension/skills/agent-network/SKILL.md) |
| Cockpit features, transports and native internals | [Cockpit reference index](cockpit/README.md#reference-and-maintenance) |
| Secret handling, vulnerability reporting and publication gates | [SECURITY.md](SECURITY.md) |
| Local three-component validation and read-only runtime diagnosis | [Development workflow](#development-workflow) |
| Development scope and documentation rules | [Contributor instructions](CLAUDE.md) |

## Development workflow

Local source gate for **app, relay and pi-extension**, before phone deployment. Run from the root; default `make` prints help. No installs, runtime preparation/replacement, service restarts or provider turns are performed by these validation targets.

```sh
make test-tooling
PNPM_NATIVE=/absolute/path/to/existing/native/pnpm \
  pi-durable-subagents hold machine -- make test-launch
PNPM_NATIVE=/absolute/path/to/existing/native/pnpm \
  pi-durable-subagents hold machine -- make validate
```

| Target | Checks (fail fast; missing prerequisites fail, never skip) |
|---|---|
| `test-tooling` | Offline fake-runner/doctor regressions, installer/publisher guards, documentation links and self-tests. Python 3, Git, Make; doctor tests also use Node when available. |
| `test-launch` | Extension typecheck/build, focused launcher/managed/session tests, real CLI/staged-release sandbox and hidden-PIN PTY tests; focused Flutter launcher/control tests plus real local cross-component acceptance. |
| `validate` | Tooling; relay fmt, warning-denying clippy and tests; extension typecheck/build and all tests/PTY; native speech JVM harness; Flutter analyze and all tests (concurrency 1). Includes the same cross-component acceptance. |

Provision dependencies explicitly first: [extension](pi-extension/README.md#build-and-install-this-source), [relay](relay/README.md#build-and-run), [Flutter](app/README.md#build-and-run), [native speech harness](app/vendor/speech_to_text/PATCHES.md#proof). Heavy targets require Node 22.19+, existing **offline native pnpm** (not Corepack/Bun/downloading shims), Rust with cached crates, cached Flutter dependencies/artifacts, usable Linux `/bin/bwrap`, and this checkout's previously prepared [Pi 1.3.0 snapshot](pi-extension/docs/secure-launcher.md#managed-runtime-packaging-api3). Full validation also requires rustfmt/clippy and the speech harness's cached Android/JDK/Gradle prerequisites.

The [runner](scripts/validate.sh) isolates HOME/Pi/XDG state, clears worker/legacy-child markers before imports, and shares only existing Pub/Cargo/Gradle dependency caches plus the Rust toolchain. It does not inherit user Cargo/Gradle config or credential files. Caches/build outputs may change; this is test-state isolation, not an environment-secret scrubber. Commands use offline/locked Rust and Gradle, Flutter `--no-pub`, and the existing pnpm offline-native mechanism.

[Local acceptance](app/test_acceptance/local_secure_launch_test.dart) crosses the actual loopback-only Rust router, extension secure launcher, and Flutter repositories/WebSocket transport: protected Start → real bundled Pi `get_state` readiness → discovery/handoff → exact Stop with client capability consumption (not a server replay test); correlated denial and missing/invalid-runtime errors are checked too. It lives outside default Flutter test discovery and is explicitly required by both root gates, without skips. Keys, PIN, settings and database are synthetic/temporary; child networking is disconnected. This and unit/widget tests are **not** native phone/microphone/provider acceptance. The explicit [Android deployment](#android-client-deployment) target adds APK and security gates; validation alone never installs a phone app.

### Android client deployment

`make deploy` updates **only the existing Android client** over ADB and opens it. It never deploys/restarts the relay or host, changes a runtime, invokes a provider, commits or pushes. First review/commit/push the intended source and complete the manual review in [SECURITY.md](SECURITY.md#before-publication-or-deployment); a tag or an earlier validation is not clearance.

```sh
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:$PATH \
PNPM_NATIVE=/absolute/path/to/existing/native/pnpm \
GITLEAKS=/absolute/path/to/verified/gitleaks ADB_SERIAL=your-authorized-serial \
  pi-durable-subagents hold machine -- make deploy
```

The [runner](scripts/deploy-android.py) fails closed on missing prerequisites, runs the full `make validate`, current-HEAD redacted Gitleaks scan, docs check and **all five locked-dependency audits** from SECURITY.md. Audits may need network access; no dependency/SDK/license provisioning is performed. Provide existing Flutter 3.44.4, JDK 17, Android SDK/build tools, accepted licenses, Pub/Flutter artifacts and Gradle 8.14 all/dependency caches. Build is release ARM64, `--no-pub`, with offline Gradle and SDK auto-download disabled; provision missing dependencies separately rather than relaxing a gate. See [mobile signing requirements](app/README.md#build-and-run); preserve the existing signing key, including the private debug key when release signing uses that fallback.

The selected device must be online and authorized; without `ADB_SERIAL`, exactly one device is required. An installed package is required. Each run removes the old output APK, freshly builds with `versionCode = max(installed + 1, pubspec + 1)` without editing pubspec, verifies SDK-reported package/version/ARM64 and matching installed APK certificates, then uses **only `adb install -r`** (never uninstall, downgrade or clear data). It rechecks installed versionCode and confirms launch with `am start -W`; this is not microphone/provider acceptance. Failures stop subsequent steps, but a failed post-install/launch check cannot roll back an already installed update.

For a candidate without installation/opening, use the same environment and lease with `python3 scripts/deploy-android.py --build-only`; this still runs every gate and requires the selected installed device for version/signature comparison. It is not an install-gate bypass or reusable deployment approval. Lightweight offline deployment regressions are part of `make test-tooling`.

### Diagnose an exact host package

```sh
make doctor EXTENSION_ROOT=/absolute/path/to/the/extension/package
```

Read-only: uses **this checkout's built validator**, not the selected package's executable code, to inspect ownership, modes, hashes, versions and bounded closure. Missing/invalid targets fail. It reads no host credentials and never prepares, copies or replaces a runtime. Build the validator separately if absent; [operator recovery](pi-extension/docs/secure-launcher.md) must respect an idle-safe boundary.

The active phone host's loaded extension path must be established independently: neither a valid source snapshot nor a registered `npm:remote-pi` package proves it. Doctor success does not establish PIN/model/auth configuration, working sandbox, live-host identity or phone readiness.

## Maintenance

Build this checkout using the linked project guides; upstream npm packages, installers and existing update URLs are not releases of this independent repository. There are no GitHub workflows; testing, building and publishing are local/manual. Review publication destinations and signing before releasing; follow the [security gates](SECURITY.md#before-publication-or-deployment).

Check documentation navigation after changes with the [lightweight tooling target](#development-workflow).

Each guide must link back to its project or this index. Keep durable facts in one owning document; use relative Markdown links for cross-project discovery. Record manual releases in the [Cockpit changelog](cockpit/CHANGELOG.md).

## License

[MIT](LICENSE). Package and third-party licenses remain in their respective directories.
The [download-server manifest](rp-s3/Cargo.toml) also declares `LicenseRef-proprietary`; that existing license discrepancy is unresolved, not relicensed by this cleanup.
