# Pi extension

[Project index](../README.md#project-map) · [Cross-project validation](../README.md#development-workflow)

Host extension, local agent broker, relay client and optional daemon supervisor. Maintainer and author of contributions: **Andrius Solopovas**.

## Build and install this source

Requirements: Node **22.19+**, pnpm and the [Pi coding agent](https://github.com/earendil-works/pi).

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
pi install .
```

This checkout is source-only; its package is marked private. The [workspace configuration](pnpm-workspace.yaml) supplies a scoped security override that npm consumers do not inherit. Do not use `npm install -g .`, pack/publish it to npm, or substitute the upstream `remote-pi` distribution. Building does not install a service.

In an interactive Pi session:

```text
/remote-pi
/remote-pi pair
```

The first command runs setup when necessary. Setup chooses an agent name and relay auto-start; agents share one machine-local broker session. Scan the pairing QR with your own [mobile client build](../app/README.md). Pairing is per machine, not per working directory.

## Relay and local configuration

Use HTTP(S) URLs in user-facing settings; transport code derives WS(S). Use HTTPS except for isolated local development.

```text
/remote-pi set-relay https://your-relay.example
/remote-pi config
/remote-pi relay stop
/remote-pi relay start
```

Relay URL precedence:

1. `REMOTE_PI_RELAY` environment variable.
2. `relay` in `~/.pi/remote/config.json`.
3. Built-in third-party relay, `https://relay-rp1.jacobmoura.work`.

The [mobile app](../app/README.md#connect-and-use) has its own relay setting and must use the same endpoint. See the [relay guide](../relay/README.md) to self-host. TLS is **not E2E encryption**; trust the relay operator. See [PROTOCOL.md](../PROTOCOL.md) for authentication and routing limits.

| Local path | Purpose |
|---|---|
| `<cwd>/.pi/remote-pi/config.json` | Agent name and relay auto-start for this directory |
| `~/.pi/remote/config.json` | Relay URL |
| `~/.pi/remote/peers.json` | Paired mobile devices |
| `~/.pi/remote/sessions/` | Broker sockets and audit logs |
| `~/.pi/remote/launcher/` | Private launcher verifier and registered projects |

A valid `REMOTE_PI_DIRECT_CONFIG` replaces, rather than merges with, the directory config; invalid/empty overrides fall back to the file. Legacy `session_name` is discarded. Never commit runtime configuration or identities. System keyrings store the host secret where available; headless Linux without a usable keyring falls back to a private `identity.json` with a warning.

Workers with `PI_SUBAGENT_CHILD=1` or nonempty `DSA_EXEC` retain local mesh membership and name/cwd locks but do not automatically expose relay rooms. `DSA_CALL` alone is metadata, not worker authority. Explicit `/remote-pi relay start` remains an opt-in; intentionally phone-managed children follow their parent-owned room lifecycle.

## Interactive commands

| Command | Purpose |
|---|---|
| `/remote-pi` | Setup/status and configured connection |
| `/remote-pi setup` | Re-run setup |
| `/remote-pi status` | Local mesh and relay status |
| `/remote-pi stop` | Disconnect this terminal, not all daemons |
| `/remote-pi pair` | Pairing QR and URI |
| `/remote-pi devices` | Paired devices |
| `/remote-pi revoke <shortid>` | Revoke a device listed above |
| `/remote-pi set-relay <url>` | Save an HTTP(S) relay URL |
| `/remote-pi relay [start\|stop\|status]` | Relay-only control; no verb toggles |
| `/remote-pi relay url <url>` | Alias for `set-relay` |
| `/remote-pi config` | Effective relay URL and source |
| `/remote-pi peers` | Discover peers |
| `/remote-pi rename <name>` | Rename this agent |

## Agent messaging and mobile controls

Discover opaque addresses with `list_peers`; copy them verbatim into `agent_send`. Unicast returns a delivery ACK (`received`, `denied` or `timeout`), not another agent's answer. A later reply uses `re` to correlate with the original message ID. Broadcast is fire-and-forget. `agent_request` is deprecated. Read the [agent-network skill](skills/agent-network/SKILL.md) for inbox/reply handling.

Mobile actions include compaction, new session, model/thinking selection and image input where supported. Model/provider capabilities come from the loaded runtime, not a fabricated catalogue. Action failures are scoped to the requesting host/room; an uncertain mutation is not automatically repeated.

Phone starts use registered projects and PIN authority. Follow [phone setup](../SECURE-LAUNCH.md) and the [host runtime prerequisites/preparation](docs/secure-launcher.md#managed-runtime-packaging-api3), which are stricter than the baseline extension requirements. Wire details belong to the [host contract](docs/secure-launcher.md), [session stop controls](docs/session-control.md) and [room display contract](docs/room-display-endpoint.md).

## Source CLI

After the frozen pnpm install and build above, invoke the CLI directly so it retains this checkout's patched dependency graph:

```sh
node dist/index.js <subcommand>
```

References to `remote-pi <subcommand>` in the command tables and [daemon guide](docs/daemon.md) mean this source CLI invocation, not a globally reinstalled npm package. Use an absolute `dist/index.js` path when running from another directory.

## Optional daemon supervisor

Daemons are distinct from PIN-protected phone-launched children. Opt into a user-level service only when intended:

```sh
node dist/index.js install
node dist/index.js create /absolute/project --name "Project agent"
node dist/index.js daemons
node dist/index.js daemon start
node dist/index.js daemon status
```

Configure/pair the project interactively first. Daemons inherit project tool permissions; running them grants real unattended tool access. Review credentials, permissions and scheduled prompt costs before enabling the service.

| Command | Purpose |
|---|---|
| `remote-pi daemon send <id> "<text>"` | Send a prompt |
| `remote-pi daemon stop` / `restart` | Stop/restart registered daemons |
| `remote-pi remove <id>` | Unregister; local config remains |
| `remote-pi uninstall` | Remove service; registry remains |
| `remote-pi cron add <id> "<expr>" "<prompt>"` | Schedule prompts; minimum interval 60 seconds |
| `remote-pi cron list` / `log` | Inspect schedules and dispatch audit |
| `remote-pi cron run <jobId>` | Dispatch now |
| `remote-pi cron enable\|disable\|remove <jobId>` | Manage a job |

Cron requires a running supervisor; flags include `--tz`, `--wake`, `--no-skip-busy` and `--catchup`. Dispatch logs are not model completion receipts. See [daemon operations and troubleshooting](docs/daemon.md) for service paths, logs and recovery.

## Troubleshooting

- Phone cannot connect: check `/remote-pi config`, matching app URL, TLS and VPN reachability.
- No peer reply: distinguish delivery ACK from a content reply; use `agent_send` with `re` rather than blocking `agent_request`.
- Launcher setup/compatibility error: verify the separate managed runtime, project registration, PIN and sandbox prerequisites; do not weaken security or restart active sessions.
- Upgrade/reload only at an idle-safe boundary. Never stop unrelated agents to make an update convenient.

## Integrations and maintenance

- [Mobile client](../app/README.md): pairing, chat and controls through the [relay](../relay/README.md); the [shared protocol](../PROTOCOL.md) owns wire/trust semantics.
- [Cockpit](../cockpit/README.md): may run Pi in a terminal, but its own remote transport is SSH, not this relay.
- [Website](../site/README.md#integrations): synchronizes the extension installer; [branding](../branding/README.md) supplies package artwork. [Download hosting](../rp-s3/README.md) is distribution infrastructure, not an agent transport.
- [Development rules](CLAUDE.md), [daemon recovery](docs/daemon.md) and [security/publication gates](../SECURITY.md).

[MIT license](LICENSE).
