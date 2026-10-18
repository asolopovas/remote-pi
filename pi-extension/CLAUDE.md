# Extension development

[Project index](../README.md#project-map) · [Host extension guide](README.md)

Work from `pi-extension/`. Setup, commands and configuration are in [README.md](README.md); wire/security contracts are in [PROTOCOL.md](../PROTOCOL.md).

- Node 22.19+, TypeScript 6, strict ESM/NodeNext; relative imports include `.js`.
- Use pnpm with the committed workspace/lockfile; npm installation loses the scoped security override. The package stays private/source-only. Validate with `pnpm typecheck && pnpm test && pnpm build`.
- Use `unknown` plus narrowing instead of unbounded `any`; typed errors at boundaries.
- Authentication uses existing Ed25519 integrations. Do not implement custom crypto or claim libsodium/E2E encryption.
- Keyring fallback, launcher credentials, Owner/room authority and mutation/no-replay checks are security boundaries. Do not weaken them.
- Relay configuration accepts HTTP(S), with precedence documented in the README.
- Preserve the event-driven `agent_send`/inbox flow; `agent_request` is legacy.
- Managed runtime preparation is separate from the extension SDK; follow [the launcher contract](docs/secure-launcher.md).
- Do not commit `dist/`, runtime state, credentials or logs. Do not reload active agents for an update.

For a task explicitly marked `[ORCH:<id>]`, read the [orchestration instructions](../.orchestration/INSTRUCTIONS.md).
