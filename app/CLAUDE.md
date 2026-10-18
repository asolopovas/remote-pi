# Mobile development

[Project index](../README.md#project-map) · [Mobile guide](README.md)

Run commands from `app/`; setup and platform requirements are in [README.md](README.md).

## Boundaries

- `domain/`: Dart entities, invariants, typed failures and repository/service contracts; no UI or infrastructure imports.
- `data/`: I/O adapters and implementations of domain contracts; no widgets or `BuildContext`. Preserve captured stack traces. Expected API errors use `AppException.create`; unexpected errors use `AppException.fatal`.
- `ui/`: feature pages, immutable state and `ViewModel<T>`; consume domain contracts through injected ViewModels, not data implementations.
- `config/dependencies.dart`: dependency composition through `CustomInjector`; use constructor tear-offs. Services/repositories are lazy singletons with disposal; use cases/ViewModels are factories.
- `routing/router.dart`: compose route paths/guards and `ViewmodelProvider`; do not construct ViewModels inside pages.

## Rules

- Snake-case files; typed async/results; relative imports within a feature and public package/barrel imports across boundaries.
- Use `context.watch/read/select`. State equality must be correct because `emit` avoids equal-state notifications.
- After async work, check `mounted`/`context.mounted` before using context. Replace chained async context callbacks with `await` plus a guard.
- Colors/type come from `ui/core/themes` (`context.colors`, `context.typo`, `kMonoFamily`), not widget-local font/color constants. Camera scrims and destructive overlays are explicit exceptions.
- Keep UI text minimal; retain accessible labels, actionable errors and risk/uncertainty confirmations.
- Silence is not explicit dictation Stop; navigation/background and real failures must release the microphone.
- Crypto uses the existing `cryptography` integration, not custom algorithms. Do not claim E2E confidentiality.
- Preserve pairing, Owner/room authority, PIN lifecycle and no-replay checks; never relax them to make a test pass.
- Add focused regressions; run `flutter analyze`, `flutter test --concurrency=1` and formatting on changed Dart files. Device/build acceptance must be reported separately.
- Do not commit SDK paths, keys, `build/`, `.dart_tool/` or Pods. Keep third-party licenses with assets.

For a task explicitly marked `[ORCH:<id>]`, read the [orchestration instructions](../.orchestration/INSTRUCTIONS.md).
