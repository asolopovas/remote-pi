# Relay development

[Project index](../README.md#project-map) · [Relay guide](README.md)

Work from `relay/`; build/run/configuration are in [README.md](README.md). Wire contracts and trust limits are in [PROTOCOL.md](../PROTOCOL.md).

- Rust edition 2024, Tokio, axum WebSockets, serde and tracing. `tokio-tungstenite` is for tests.
- Validate `cargo test`, `cargo clippy -- -D warnings` and `cargo fmt --check`.
- Use typed errors/propagation, not production `unwrap`/`expect`; tracing, not `println!`.
- Never log envelope bodies, key material or signatures; never persist message payloads.
- SQLite contains signed membership metadata only. Do not strengthen the documented ownership guarantees beyond the actual signature/list-membership check.
- Preserve bounded auth caches, rate limits, strict protocol validation and fail-closed errors.
- Do not commit `target/` or runtime databases. Use the [deployment runbook](deploy/fn/README.md) for certificate/backup/upgrade operations; do not restart unrelated services.

For a task explicitly marked `[ORCH:<id>]`, read the [orchestration instructions](../.orchestration/INSTRUCTIONS.md).
