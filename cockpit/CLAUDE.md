# Cockpit development

[Project index](../README.md#project-map) · [Cockpit guide](README.md)

Work from `cockpit/`; requirements and commands are in [README.md](README.md).

## Architecture

- Features live under `lib/app/<feature>/{domain,data,ui}`. Each `<feature>_module.dart` composes its routes and binds using `flutter_modular`.
- Within a feature: `ui → domain ← data`; domain does not import UI/data/modules. Features may import `core`, not each other; core never imports a feature.
- Core contains app-global or genuinely shared services. Its module has no path and root-owned binds. App root only composes modules.
- Page ViewModels are `ChangeNotifier` instances provided by routes; never construct them in pages. App-global `SettingsController` lives above `ShadcnApp` in `ModularApp.provide`.
- Register constructor tear-offs (`Foo.new`), not factories manually calling `inject`. Named factory interfaces and value objects avoid ambiguous auto-injector parameter parsing.
- Async setup resolves in `main`, not synchronous module registration. Dialog-local controllers are passed through constructors and disposed after the dialog.
- Agent execution is terminal-first. Do not restore the removed native RPC-agent/composer UI or relay gateway. Remote workspaces use SSH plus `cockpit-server`.
- Read [terminal instructions](lib/app/core/terminal/CLAUDE.md) and [flow control](docs/terminal-output-flow-control.md) before touching terminal engines/PTY/rendering. Dependency overrides/native assets must stay compatible.

## UI and lifecycle

- Use `context.watch/read/select`; `pushNamed` stacks, `navigate` replaces the base. Keep shared paths in `core/routes.dart`.
- Use theme colors/type (`context.colors`, `context.typo`) and clamping scroll physics; never add bounce or widget-local font/color constants.
- Guard `mounted`/`context.mounted` after async work; do not capture context in chained async callbacks.
- Every user-facing change needs en, pt-BR and es keys in `lib/i18n/*.i18n.json`, with identical structure/placeholders. Run `dart run slang` and commit required generated source.
- Widgets use `context.t`, not global `t`, so locale changes rebuild. Non-widget one-shot notifications may use global `t`.
- Data/ViewModels return typed errors, translated at the UI boundary. Preserve raw third-party stderr as detail. CLI/protocol output, proper names and model IDs are deliberately not translated.
- Widget tests need `TranslationProvider`.

## Validation

Run `flutter analyze`, `flutter test` and format changed Dart files. Native build/package checks are separate; use [packaging/README.md](packaging/README.md). Do not claim platform/device acceptance from unit tests. Do not commit build output, Pods, runtime/SSH/database configuration or credentials.

For a task explicitly marked `[ORCH:<id>]`, read the [orchestration instructions](../.orchestration/INSTRUCTIONS.md).
