# Local Cockpit packaging and release

[Project index](../../README.md#project-map) · [Cockpit guide](../README.md)

All builds, checks and publication are manual/local. There are no GitHub workflows. This guide owns packaging/signing; use the [development guide](../README.md#develop) for the toolchain and the [security gates](../../SECURITY.md#before-publication-or-deployment) before publishing anything.

## Identity and version

- Version/build number: [pubspec.yaml](../pubspec.yaml); record the matching release in [CHANGELOG.md](../CHANGELOG.md).
- Platform identifiers/resources: [macOS configuration](../macos/Runner/Configs/AppInfo.xcconfig), [Windows resources](../windows/runner/Runner.rc), [Linux configuration](../linux/CMakeLists.txt).
- Existing application IDs and publisher fields are upstream-compatible values, not permission to sign or publish as that operator. Choose independent publisher IDs, signing credentials and download destinations before distributing a new product identity.
- Keep signing material in a private keychain/secret manager with an out-of-band backup. Never commit P12/P8 files, keystores, passwords or private update keys.

Run packaging commands from `cockpit/`. Install [Fastforge](https://pub.dev/packages/fastforge) locally if needed:

```sh
dart pub global activate fastforge
```

The [distribution options](../distribute_options.yaml) and platform-specific configurations own package settings, not a second list in this guide.

## macOS

Requires macOS, Xcode/CocoaPods and your own Developer ID plus App Store Connect notarization credentials. Follow the configured entitlements and native helper build scripts; do not bypass Gatekeeper or library validation to make a release start.

```sh
flutter build macos --release
fastforge package --platform macos --targets dmg
```

Before distribution, sign the app and nested helpers/frameworks with your Developer ID and hardened runtime, create/sign the DMG, submit it using `xcrun notarytool submit --wait` with privately stored credentials, and staple the accepted ticket. Verify both the app and final artifact:

```sh
codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/Cockpit.app
spctl --assess --type execute --verbose=2 build/macos/Build/Products/Release/Cockpit.app
# Run on the final DMG after notarization; substitute its actual path:
xcrun stapler validate /absolute/path/to/Cockpit.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 /absolute/path/to/Cockpit.dmg
```

A successful local build is not notarization or acceptance on another Mac. Keep signing/notarization receipts privately; never claim them from a previous publisher's release.

## Windows

Build on Windows with the Flutter desktop toolchain and Inno Setup. The [EXE configuration](../windows/packaging/exe/make_config.yaml) owns installer options.

```sh
flutter build windows --release
fastforge package --platform windows --targets exe
```

Verify an owned Authenticode signature and test install/launch/uninstall on Windows before public distribution. An unsigned local build is not a signed production release; do not bypass SmartScreen/signature checks as a release procedure.

## Linux

Build natively for each supported x86_64/arm64 target. Beyond Flutter's desktop prerequisites, Debian/Ubuntu build dependencies include `libsecret-1-dev`, `libasound2-dev`, `libmpv-dev`, `libjsoncpp-dev` and `rpm` for RPM packaging. Install these through the machine's normal package-management policy.

```sh
flutter build linux --release
fastforge package --platform linux --targets deb
fastforge package --platform linux --targets rpm
```

Runtime dependencies are maintained in the [DEB](../linux/packaging/deb/make_config.yaml) and [RPM](../linux/packaging/rpm/make_config.yaml) configurations. Inspect the final native-library closure with `ldd` on trusted locally built artifacts and test clean installation on each target distribution.

After an aborted configure, inspect `build/linux/<arch>/release/CMakeCache.txt`: a stale `/usr/local` install prefix can cause a permission error. Remove only that owned generated cache/CMakeFiles directory after confirming no build is using it; do not rerun the build as root.

For hybrid-GPU diagnosis, use [Linux profiling](../docs/linux-performance-profiling.md); do not change the machine-wide graphics environment to package Cockpit.

## Headless server bundle

The server version must match the client. Follow the [remote-host build/install instructions](../README.md#remote-host), which own the source build command and service lifecycle. The [bundle builder](../tool/build-server-zip.sh) creates a native Linux ZIP containing `bin/`, `lib/`, `VERSION`, an installation script and a SHA-256 `bundle.manifest`.

Build each architecture locally. Check the manifest, `--version`, smoke startup and SSH connectivity before shipping. The [download installer](../install-server.sh) requires an explicit `COCKPIT_REPO`; it never chooses the upstream publisher implicitly.

## Independent updates and publication

Native automatic updating is disabled. No default feed/key is accepted; enabling a paired owned feed and verification key requires a separately validated client implementation. Producing a signed appcast does not enable that updater. Manual update notifications are also disabled by default: the root supplies no feed. The explicit HTTPS test seam rejects invalid URLs and redirects; enabling owned distribution still requires separate validation.

For a manual release:

1. Run local project tests/builds and platform-specific packaging/signature checks; keep the version, changelog, server bundle and checksums consistent.
2. Publish binary assets only to the explicitly selected independent repository after reviewing their contents and required notices. Git tags do not run builds or uploads.
3. If using [manifest hosting](../../rp-s3/README.md#routes-and-operation), upload signed appcasts before `latest.json`. Use an owned HTTPS destination, keep Bearer credentials out of arguments/logs, reject cross-origin redirects and require successful status responses. No upload occurs automatically.
4. Verify the [website consumer](../../site/README.md#integrations), download URLs and actual target-platform install behavior. An uploaded file is not installed-device acceptance.

Keep the [PTY](../plugins/cockpit_pty/LICENSE), [terminal](../lib/app/core/terminal/xterm/LICENSE), [icon](../assets/file_icons/LICENSE) and bundled JavaScript notices in distributions. Review root [licensing](../../README.md#license) before distributing the download-server component.
