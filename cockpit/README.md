# Cockpit

[Project index](../README.md#project-map)

Flutter terminal workspace with files, Git/worktrees, databases and tasks. Remote workspaces use SSH and `cockpit-server`, not the Remote Pi relay. Maintainer and author of contributions: **Andrius Solopovas**.

## Develop

Use Flutter 3.47.5 with Dart compatible with [pubspec.yaml](pubspec.yaml) (`^3.12.0`); older SDK dependency pins can prevent resolution. All validation/builds are local. Native builds also need Rust/Cargo and Zig 0.16.0 where Ghostty is compiled, plus the platform's Flutter desktop toolchain. Git dependency overrides in `pubspec.yaml` are intentional pins; update them only with native-asset compatibility checks.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d linux            # or macos/windows on that platform
```

Read [CLAUDE.md](CLAUDE.md) for feature boundaries, localization and terminal rules. The agent runs as a process in a terminal; the removed native RPC-agent UI is not a supported path.

## Package map

These are code locations, not separate products or copies of the setup guide. The Flutter app depends on core, remote and keep-awake packages; it must not import the native engine directly.

| Component | Source entry point | Responsibility |
|---|---|---|
| `cockpit_core` | [library](packages/cockpit_core/lib/cockpit_core.dart) | Shared service contracts, SSH infrastructure and secret storage |
| `cockpit_protocol` | [library](packages/cockpit_protocol/lib/cockpit_protocol.dart) | Shared JSONL requests/replies; [wire reference](docs/remote-protocol.md) |
| `cockpit_remote` | [library](packages/cockpit_remote/lib/cockpit_remote.dart) | Client proxies using core/protocol |
| `cockpit_engine` | [library](packages/cockpit_engine/lib/cockpit_engine.dart) | Native filesystem/Git/PTY/database implementations for the headless engine |
| `cockpit_server` | [library](packages/cockpit_server/lib/cockpit_server.dart), [executable](packages/cockpit_server/bin/cockpit_server.dart) | Dart host executable using core, engine and protocol; direct database dependencies support native-asset bundling |
| `cockpit_keepawake` | [library](packages/cockpit_keepawake/lib/cockpit_keepawake.dart) | Platform power-management helpers |
| `cockpit_pty` | [plugin guide](plugins/cockpit_pty/README.md) | Native Flutter PTY plugin; distinct from the headless engine's PTY implementation |
| `cockpit` CLI | [Rust entry point](cli/src/main.rs), [command reference](cli/text/skill.md) | Internal automation/status executable, not the Dart server |

The `tool/wave0` and `tool/wave4` packages are non-production spikes/acceptance tools, not additional runtime services.

## Remote host

On a matching Linux x86_64/arm64 build machine, create a bundle from this source:

```sh
./tool/build-server-zip.sh "$PWD/build/server-release"
```

Copy the resulting ZIP to the host, unpack it and run its `cockpit-server/install.sh`. Keep the app and server versions matched. The installer verifies its bundle, smoke-tests it, installs under `~/.cockpit/server` and links `~/.local/bin/cockpit-server`. Connect using the app's SSH host settings.

```sh
cockpit-server --version
cockpit-server service install     # optional systemd user service
cockpit-server service status
cockpit-server service uninstall
```

[install-server.sh](install-server.sh) downloads prebuilt GitHub releases only from an explicitly supplied `COCKPIT_REPO`; there is no default publisher. Use it only after publishing compatible releases of your own and setting `COCKPIT_REPO=owner/repository`. Review update/download destinations before distributing clients.

## Reference and maintenance

- [Packaging and signing](packaging/README.md); keep the version in [CHANGELOG.md](CHANGELOG.md) consistent with the manually published build.
- [Remote protocol](docs/remote-protocol.md) and [Windows SSH setup](docs/windows-host-setup.md).
- [Tasks](docs/tasks-json.md), [layouts](docs/layout-ckp.md), [notebooks](docs/notebook.md) and [themes](docs/theme-format.md).
- The [CLI skill](cli/text/skill.md) owns automation verbs plus [board](cli/text/skill.md#board-files-kanban) and [panel](cli/text/skill.md#panel-files-panel) formats.
- [Agent status hooks](docs/turn-status-hooks.md) and [terminal flow control](docs/terminal-output-flow-control.md).
- [Telemetry](docs/telemetry.md), [Linux profiling](docs/linux-performance-profiling.md) and the [synthetic terminal benchmark](benchmark/README.md). These cover different workloads; benchmark results are not device/deployment acceptance.

## Related projects

The [website](../site/README.md#integrations) presents Cockpit and its downloads; the [download server](../rp-s3/README.md#integrations) hosts release manifests. The [mobile Pi client](../app/README.md), [host extension](../pi-extension/README.md) and [relay](../relay/README.md) form the separate phone-control path. [Security/publication gates](../SECURITY.md) apply to all components.

Local workspace/database/SSH configuration belongs outside Git. Keep terminal, PTY, icon and bundled JavaScript licenses with distributions; the JavaScript notice files are packaged beside the assets.

Local security regressions (run from `cockpit/`):

```sh
python3 test/security/test_release_updater_configuration.py
# Supply jsdom 29.1.1 through an isolated tooling prefix, not app dependencies:
NODE_PATH=/absolute/tooling/node_modules node --test test/md_preview_security.cjs
```

The preview checks disable network/resource execution and exercise the unchanged browser APIs; they do not prove native WebView/CSP or installed-device behavior.
