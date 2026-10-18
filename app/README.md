# Mobile client

[Project index](../README.md#project-map) · [Cross-project validation](../README.md#development-workflow)

Flutter client for Android and iOS. Maintainer and author of contributions: **Andrius Solopovas**.

## Build and run

Use Flutter 3.44.4 with Dart compatible with [pubspec.yaml](pubspec.yaml) (`^3.11.5`). All validation/builds are local. Install the Android SDK/JDK 17 for Android, or Xcode/CocoaPods on macOS for iOS.

```sh
flutter pub get
flutter analyze
flutter test --concurrency=1
flutter run
flutter build apk --release --target-platform android-arm64
# macOS with the iOS SDK:
flutter build ios --no-codesign
```

For a gated fresh release build and replace-only ADB update, use the canonical [Android client deployment workflow](../README.md#android-client-deployment). It preserves app data/signing compatibility and does not deploy host services.

Ordinary `flutter test` runs unit/widget tests only. The separate Linux native [launch acceptance](test_acceptance/local_secure_launch_test.dart) requires the [root gates](../README.md#development-workflow), which build and explicitly run it with the real relay/extension and managed Pi runtime.

Android requires API 34+; iOS targets 18+. Account, backup and screen-lock prerequisites are owned by the [identity plugin's platform requirements](packages/remote_pi_identity/README.md#platform-requirements).

The Android application ID is `io.github.asolopovas.remotepi.readable`, with label **Remote Pi Readable**, so it installs separately from the upstream application. The namespace remains unchanged for native compatibility. Supply release signing through ignored `android/key.properties`; without it, Gradle uses the local debug key even for release-mode builds. Preserve the signing key privately for compatible updates. No APK or signing key is included here.

## Connect and use

1. Build/install this client.
2. Follow the [host extension setup](../pi-extension/README.md#build-and-install-this-source) and display its pairing QR.
3. Scan the QR code. Use the same HTTP(S) endpoint as the host; see [relay setup](../relay/README.md#self-host-with-docker).

Pair this copy independently; existing installations and their data are not migrated. TLS is not E2E encryption. See the [protocol](../PROTOCOL.md) and [secure launcher guide](../SECURE-LAUNCH.md).

The readable client bundles Fira Mono Nerd Font, supports collapsible/wrapped tool output and local dictation. On Android the vendored speech plugin requires an available on-device recognizer and fails closed rather than falling back to cloud recognition; review text before sending. Source and host tests do not establish microphone/model availability or physical-device acceptance.

## Maintain

See the [development instructions](CLAUDE.md) for layer boundaries and dependency composition. Local packages and regression references:

- [Owner identity storage](packages/remote_pi_identity/README.md), used by the [shared pairing/membership protocol](../PROTOCOL.md).
- [Vendored speech API](vendor/speech_to_text/README.md) and [local on-device patch contract](vendor/speech_to_text/PATCHES.md).
- Cross-project [session controls](../pi-extension/docs/session-control.md) and [display snapshots](../pi-extension/docs/room-display-endpoint.md); coordinate both endpoints when changing these.
- [Inert renderer fixtures](test/ui/chat/fixtures/75/README.md); these are presentation data, not executable commands.
- [Website/source-guide links](../site/README.md#integrations) and [release manifest hosting](../rp-s3/README.md#integrations). [Cockpit](../cockpit/README.md) is a separate client/SSH architecture, not this app's backend.

Licenses: [MIT](../LICENSE), Fira Mono [OFL](assets/fonts/fira_mono/LICENSE), and [vendored speech plugin](vendor/speech_to_text/LICENSE). The `highlight` dependency is MIT © 2019 Rongjian Zhang; Flutter collects dependency licenses. Keep required assets and native resources, but never commit `build/`, SDK paths, credentials or signing material.
