# PIN-protected project launcher (machine/App contract)

[Project index](../../README.md#project-map) · [Host extension guide](../README.md)

User workflow: [phone launcher](../../SECURE-LAUNCH.md). Endpoint integration: [mobile client](../../app/README.md), [extension setup](../README.md) and [session stop/access controls](session-control.md). The shared [protocol](../../PROTOCOL.md) owns transport and identity semantics.

This surface controls only this host session's newly launched agents. It does not take over existing Pi sessions, change Relay membership, stop unrelated agents, or shut down the operating system. Linux with working `/bin/bwrap` is required; there is no unrestricted fallback.

## Initial PIN from phone / local operator setup

A currently paired phone may create the **first** PIN on a supported root host via the additive contract below. Existing, corrupt or unsafe verifier files require local operator recovery; remote setup never replaces them. No default PIN exists. Project registration and credential/sandbox prerequisites remain local.

For local setup/reset, build the extension using its already installed dependencies, then run:

```sh
node /absolute/path/to/pi-extension/dist/bin/launcher.js pin-setup
node /absolute/path/to/pi-extension/dist/bin/launcher.js project-add 'My project' /absolute/project --allow /absolute/project --allow /absolute/extra-folder
node /absolute/path/to/pi-extension/dist/bin/launcher.js project-list
node /absolute/path/to/pi-extension/dist/bin/launcher.js project-remove <project-id>
```

`pin-setup` requires an interactive local terminal, hides input and confirms it. Supply your own 6–12 digit PIN: **no default exists**. Neither CLI arguments nor environment variables accept a PIN. PINs are never logged or stored as plaintext; the verifier uses random 32-byte salt and scrypt (N=32768, r=8, p=1). Synthetic PINs in tests are not operator configuration.

Local data is `~/.pi/remote/launcher/{pin,projects}.json`, files 0600 in a 0700 directory, atomic rename + fsync. Cross-process transactions serialize local edits, PIN resets and persisted attempt/cooldown updates. A crashed transaction leaves `transaction.lock`: operations fail closed; an operator must establish no setup/unlock transaction is alive before removing that stale lock locally. Do not blindly delete locks.

Register exact absolute canonical directories, not glob patterns or a home/system root. Cwd must be within one explicitly allowed folder. Symlink components, `.`/`..`, replacements of any recorded ancestor/directory, host Pi credential directories and runtime overlap are rejected. Removing/re-adding a project creates a new ID. Registry listing is not a filesystem index: it never enumerates unregistered directories, and the phone cannot write registry/configuration or replace a PIN.

Before launch, writable roots are descriptor-pinned and scanned without following symlinks, with a shared 100,000-entry / 5-second / 128-level budget. Hardlinked regular files, nested mounts/filesystems, sockets/FIFOs/devices, inaccessible or oversized trees fail closed. An existing pnpm/hardlinked dependency tree can consequently be unavailable: prepare a private normal-file working copy or smaller project **locally**, then register it; the launcher never deletes, dereferences, changes caches, or silently excludes user files. Launch errors report the preflight category, not file contents. Local `project-list` reports only registered metadata; launch performs the full preflight.

A usable **stored** Pi model credential in `PI_CODING_AGENT_DIR/auth.json` (default `~/.pi/agent/auth.json`) must exist and be private 0600. Use local Pi `/login` if needed; no credentials are invented. Both global `defaultProvider` and `defaultModel` must be configured; only that provider's credential is copied. Missing/partial defaults fail before a child is admitted. Only validated `defaultProvider`/`defaultModel` settings accompany it. The fixed host `settings.json` may be a dotfiles symlink: resolve it locally, then open the canonical final path with `O_NOFOLLOW` and validate the descriptor (regular file, current user, at most 128 KiB, not world-writable). Normal 0664 public settings remain supported without chmod or mutation; reads remain bounded even if a file grows. The canonical settings file and agent directory cannot be included in writable project roots. No remote-supplied settings path is accepted. `auth.json` remains nonsymlink/private; settings compatibility never relaxes credential checks. Literal API keys and OAuth records are supported; host credential commands, environment-only/ambient credentials, arbitrary `models.json`, skills/packages/custom providers and project extensions/settings are not inherited. OAuth refreshes affect only the private child copy. Model selection on the child can select models whose copied provider credential is usable.

For a **future new host process**, not a reload of existing agents, use the operator's explicit trusted endpoint. Example from the intended host working directory, with built extension and an already installed compatible Pi:

```sh
REMOTE_PI_RELAY=https://your-relay.example \
REMOTE_PI_DIRECT_CONFIG='{"agent_name":"phone-launch-host","auto_start_relay":true}' \
pi -e /absolute/path/to/pi-extension/dist/index.js
```

This sets a process-local endpoint override, not global configuration. HTTP(S) is the extension configuration form; HTTPS derives WSS internally. Do not disable TLS validation. The phone must use the same Relay endpoint and select this host room. If restored Relay membership does not include its current machine/Owner relationship, reconcile membership explicitly on the phone/operator side; this component does not migrate/change existing pairings. Children reuse parent-owned authenticated machine identity/Owner membership and do **not** need separate QR pairing. No production launch/configuration/activation was performed by implementation tests.

## Frozen additive phone wire contract

Inner JSON travels through the existing authenticated Relay/paired Owner channel. The machine derives Owner from that channel, never payload aliases. Unknown/extra fields, invalid IDs, remote paths/env/commands/flags are rejected. IDs and authority strings are nonempty, control-free strings <=128 characters; optional `name` <=80 characters. PIN is a string matching `^[0-9]{6,12}$`. Use unique IDs for mutations, especially unlock.

```ts
interface LauncherStatus {
  launcher_api?: number; // new hosts emit 3; exact configured model/readiness support, never authority
  launcher_id: string;
  epoch: string;
  configured: boolean;
  pin_setup?: "available" | "configured" | "unavailable"; // omitted by old hosts
  unlocked: boolean;
  expires_at: number | null; // epoch milliseconds, this Owner only
  cooldown_until: number;  // epoch milliseconds, shared local verifier cooldown
}
type LauncherRequest =
  | { type: "project_list" | "launcher_status"; id: string }
  | { type: "launcher_unlock" | "launcher_pin_initialize"; id: string; launcher_id: string; epoch: string; pin: string }
  | { type: "launcher_lock" | "launcher_shutdown"; id: string; launcher_id: string; epoch: string }
  | { type: "project_launch"; id: string; launcher_id: string; epoch: string; project_id: string; name?: string }
  | { type: "launcher_agent_stop"; id: string; launcher_id: string; epoch: string; agent_id: string };
type LauncherResult =
  | { type: "project_list_result"; in_reply_to: string; projects: {
      project_id: string; name: string; cwd: string; allowed_folders: string[]
    }[] }
  | { type: "launcher_status_result"; in_reply_to: string; status: LauncherStatus }
  | { type: "launcher_shutdown_result"; in_reply_to: string; stopped: boolean; status: LauncherStatus };
```

Mappings and prerequisites:

| Request | Response | Prerequisite |
|---|---|---|
| `launcher_status` | `launcher_status_result` | Currently paired host Owner |
| `launcher_pin_initialize` | `launcher_status_result` | Current root paired Owner/channel, current launcher+epoch, safely absent verifier only; after publication and final authority checks, rotates epoch and unlocks only initiating Owner |
| `launcher_unlock` | `launcher_status_result` | Current launcher+epoch, local verifier, correct PIN, no cooldown |
| `launcher_lock` | `launcher_status_result` | Currently paired host Owner, current launcher+epoch (can revoke even while locked) |
| `project_list` | `project_list_result` | Current paired Owner **and unexpired unlock** |
| `project_launch` | existing `agent_launch_result` | Current launcher+epoch, paired unlocked Owner, exact registered project ID and successful sandbox/preflight |
| `launcher_agent_stop` | existing `agent_stop_result` | Current launcher+epoch, paired unlocked Owner, this launcher's requesting Owner's agent ID |
| `launcher_shutdown` | `launcher_shutdown_result` | Current launcher+epoch and paired unlocked Owner; revoke before cleanup |
| existing `agent_list` | existing `agent_list_result` | Paired unlocked Owner; snapshot contains only that Owner's records |

Existing launch/stop result `agent` fields remain: `agent_id`, `name`, `cwd`, `room_id`, `state` (`starting/running/stopped/failed`), optional `error`. Agent-list fields remain `available`, optional `launcher_id/reason`, `cwd`, `max_agents` (4), `agents`.

Failures use existing correlated `error` (`in_reply_to`, `code`, `message`), normally `invalid_message`; managed lifecycle can also return `rate_limited`, `timeout`, `internal_error`. Refresh status after unlock failure to obtain cooldown/epoch. `launcher_api:3` guarantees exact configured built-in defaults and model-verified readiness for new starts. API2 hosts still support existing child access/control, but must not receive new phone starts from the upgraded App. The field cannot bypass pairing/PIN checks. Known settings/auth/runtime/sandbox prerequisites return fixed actionable preflight errors, never raw JSON, stderr, credentials or sensitive paths. Unexpected startup/preparation failures report an unexpected host failure, not an invented missing-Pi/PATH diagnosis. The server never echoes the PIN. Legacy arbitrary-cwd `agent_launch` and legacy `agent_stop` are refused; they cannot bypass the protected contract.

### App sequencing/security UX

1. Select the paired host; request `launcher_status` and wait for its reply (initial channel attachment is asynchronous).
2. Offer Create PIN/confirm **only** for `pin_setup:"available"`. Both entries must match; submit a fresh `launcher_pin_initialize` ID with the current launcher/epoch, then clear inputs immediately. Adopt the returned epoch/status: new hosts grant the initiating Owner only (`unlocked:true`), so proceed to project selection. Older hosts may remain locked: require normal unlock without retaining/replaying the creation PIN. `configured` means use the existing PIN; `unavailable` requires local inspection. Omitted `pin_setup` is an old host: explain local setup is required, never attempt remote setup.
3. Submit a fresh unlock ID with current `launcher_id`/`epoch`; clear the PIN immediately and never retain/replay it.
4. Adopt the returned status/epoch, then fetch `project_list` and `agent_list`. Start only a returned `project_id`; `cwd`/folders are descriptive, not launch inputs.
5. Refresh status after Lock, shutdown, reconnect/expiry or stale authority errors. Do not retain/replay security mutations or substitute a new epoch into an old mutation ID.

Grants last five minutes, are Owner+launcher scoped, and are never restored after host restart/session reload. Verifier replacement invalidates old grants. Wrong attempts impose persisted exponential cooldown from two seconds up to five minutes; only one slow verification is admitted at a time and no attempt-history key is evicted to enable replay. Initialization and unlock share one single-flight and non-evicting credential request-ID budget (256 IDs total, no PIN payload retained). Initialization uses the same private scrypt record and cross-process transaction lock as local setup, with atomic create-only publication and renewed pairing/channel/lifecycle/epoch checks after derivation and immediately before publication, then **after all asynchronous publication/cleanup and transaction-lock release**. Only a still-current paired initiating Owner receives a fresh five-minute fingerprint-bound grant; other Owners remain locked. A concurrent Lock/revoke/disconnect/lifecycle change wins: setup may be durably configured but locked, with no overwrite or rollback. Refresh status to reconcile. Existing verifier cooldowns cannot be reset by initialization. Mutation/credential-check histories are bounded (256); refresh/restart rather than guessing acceptance after capacity errors.

Every successful unlock rotates the global epoch, invalidating pending old-epoch admissions; already-unlocked other Owners keep their remaining expiration but must obtain the new epoch via status. **Lock is global for this launcher**, invalidates all grants/replay authority before any await and leaves already-running children alive. Parent-mediated child-room controls/history/output are also gated; a paired locked caller receives a correlated denial, not child data. Work accepted before Lock can continue in the background; Lock is not a rollback of completed actions.

Protected host list/launch/stop replies retain the producing launcher and admission epoch. After the final paired-Owner lookup they synchronously recheck the grant, epoch, launcher identity, root lifecycle generation and actual active channel immediately before sending. Status, Lock and shutdown acknowledgements are intentionally not grant-gated.

Shut down means **“Stop your managed agents and lock access.”** It stops only requesting Owner's children in this launcher and globally locks access; other Owners' children and unrelated agents remain running. `stopped:true` means all requesting Owner cleanup completed, including starts in flight. `stopped:false` means incomplete cleanup and access remains locked; inspect locally or unlock and submit a fresh shutdown request to retry safely. Neither operation invokes OS shutdown. Normal host teardown terminates all children it owns.

## Sandbox and parent/child transport scope

The complete child Pi process and its commands run under bubblewrap private mount/user/PID/IPC/UTS namespaces, dropped capabilities, disabled nested user namespaces and parent-death cleanup. Only explicit allowed host folders are writable; exact cwd and folder inodes are pinned, protecting replacement during launch. System binaries/libraries (`/usr`, `/bin`, `/lib*`), DNS/TLS files, the current Node executable, installed Pi package, extension package and cached dependency tree are explicit **read-only runtime allowances**. No host root/home bind, host `~/.pi/remote`, broker UDS, pairing records, signing secret, worker/session identity or arbitrary resource config is exposed. Private HOME/tmp/sessions live on namespace tmpfs. Credential copies pass through immediately unlinked 0600 descriptors and disappear with namespace teardown.

This is OS-enforced **filesystem isolation**, not merely cwd allowlisting and not perfect isolation: allowed mounts change real host files; the selected provider's model credentials are readable by project code; network (including reachable host/local services) remains available and credentials/data can be exfiltrated. It does not defend against a compromised host/kernel or concurrent malicious same-UID local changes after preflight (including newly introduced hardlinks). No automatic mutation/deletion of user files occurs.

Bubblewrap 0.9.0 closes inherited Node IPC fd3 (`--preserve-fds` is unavailable and `--sync-fd` does not pass it to the child). A private preload demultiplexes **namespaced, typed managed frames** over the already inherited stdin/stdout pipes and preserves ordinary Pi RPC JSONL. It has UTF8-safe LF framing, 6MB total/partial frame limits, strict internal fields/directions, monotonic sequences and fail-closed EOF/error/backpressure cleanup. This is not a shell/eval/env/signing/routing endpoint. The parent treats all child output as untrusted and allows only assigned-room protocol events to the launching paired Owner. The parent alone owns per-child Relay challenge signing and paired-owner checks. Readiness requires both actual Pi `get_state` success and successful parent authenticated room publication; timeout/failed publication cleans the child up. No child mesh endpoint exists.

Managed child rooms support bounded existing text/image messages, queue set/clear, cancel, ping, session history, model/thinking selection, model listing and simple extension UI replies. Structured `ask` replies, session-new/compact and arbitrary session/file operations are not enabled by this narrow bridge. The proxy does not automatically restart children or recreate a dropped child-room Relay connection; use the still-owned host list/stop surface after connectivity recovery. Ordinary unrelated Pi rooms keep their prior transport behavior.

### Managed output bounds and observational metadata

All managed Relay writes (hello/auth, event envelopes, denials and metadata controls) use a **12,000,000-byte** cap. Admission conservatively sums WebSocket `bufferedAmount`, bytes reserved until send callbacks complete, and the next UTF8 frame plus 14 bytes of WS framing. Event accounting includes base64/JSON expansion. There is no retry queue. Overflow, send exceptions, callback errors or lost transport terminate that room immediately and SIGKILL only its assigned managed child; accepted queued output is not drained after failure. Ordinary interactive `send`/`sendControl` semantics are unchanged. This is a bridge queue bound, not a general child compute/disk/network quota.

The private `managed_metadata` frame carries only an epoch and an exact snapshot of `working:boolean`, optional control-free `model:string` (1–256 characters), and optional enumerated `thinking`. It has no room, Owner, signing, arbitrary-field or remote interface. Startup seeds the SDK snapshot; turn_start/turn_end and model/thinking selection update it. The parent selects the assigned room and retains at most one latest snapshot, coalescing/rate-limiting publication to at most ten updates/second through the same bounded send surface. Brief turns may be coalesced.

**Locked metadata policy:** only a currently paired launching Owner/current live child may publish `working` while locked; no updated model/thinking or other project-controlled strings, protected events/output/history are sent. This allows Home to reflect already-accepted work continuing after Lock. With a valid current grant, model/thinking may also be published. A fresh unlock can republish the latest full snapshot only after renewed admission. Final asynchronous pairing/authorization checks are followed by synchronous epoch/grant/lifecycle/child checks. Lock does not erase metadata already disclosed and cached by Relay/App, or recall frames already admitted before revocation. Working patches do not replace cached previously-disclosed model/thinking values in the existing Relay contract.

These are private host changes only: Relay uses its existing `room_meta_update` → `room_meta_updated` contract and frozen App Home consumes `meta.working` through ConnectionManager, independently of the active chat. No App wire types change.

## Setup uncertainty and transport limits

Never journal, log, put in chat/history, auto-replay or retain PIN-bearing frames. After a lost setup response/reconnect, clear inputs and request fresh status; do not replay the mutation or assume success/unlock. Once publication is submitted under current authority, later revocation cannot roll back the durable write (nor frames already admitted). A filesystem/fsync failure may leave a configured verifier despite an error; status reconciliation, not retry, resolves uncertainty. There is no remote reset/recovery. The existing authenticated TLS Relay transport is **not end-to-end encrypted**: the Relay operator remains in the trust boundary. Request IDs are not secrets; use unique IDs.

Session-origin metadata and recovery are specified once in [managed session access](session-control.md#managed-session-access-and-launching-host).

## Managed runtime packaging (API3)

The [extension SDK dependency](../package.json) is **not** the secure child runtime. The child requires a separately installed bundled Pi 1.3.0 and host Node **22.19+**; older SDK catalogues/adapters cannot substitute for that runtime. Built-in model defaults must be validated before publication.

On the host, prepare once (offline, under the machine lease for builds/tests):

```sh
node scripts/prepare-managed-runtime.mjs
```

The script resolves `pi` through the host-local PATH, follows its legitimate CLI
symlink, and accepts the validated published **Pi 1.3.0 bundled CLI** layout only.
It never imports the extension's old SDK to find the new runtime. It creates
`build/managed-runtime` inside this extension package, with private immutable
files/directories (0400/0500), a SHA256 manifest, and no source hardlinks/symlinks:

- Pi's package metadata, README, complete `dist` (bundled CLI, modern adapter,
  virtual SDK bridge, lazy chunks, workers, assets and unbundled support files).
- Only its external bundle/extension-loader dependencies: `typebox` 1.3.27,
  `undici` 8.10.2, `jiti` 2.7.0, `@silvia-odwyer/photon-node` 0.3.4 (WASM included).
- Matching Pi AI 1.3.0 public bundled provider catalog data, for recognition and
  trusted expected metadata. No user catalog cache or account pool.

No downloads, lockfile changes, whole global package tree mounts, credentials,
resource configuration or user extensions are involved. Preparation is bounded
at 15,000 entries/160 MiB and rejects unsafe source ownership/permissions and
symlink entries. Bun package-cache source hardlinks are copied as bytes, not
linked. Source public metadata in the user's primary group may be 0664; the
snapshot is always private and nonwritable. An existing snapshot is not replaced
implicitly. Its owner must explicitly unseal/remove it and prepare a replacement
only when no managed child uses that package. Do not reload a root with children.

Every launch validates the entire snapshot's entries, ownership, read-only modes,
file hashes and required package versions (5-second bound), rejects overlap with
registered writable folders, and mounts the snapshot read-only. The child uses
the host's Node >=22.19, a minimal private agent directory and selected-provider
private auth. Runtime commands/paths/options are not remotely selectable. Staging
an installed release must copy the snapshot too, preserving modes; copying just
`dist` and old `node_modules` is insufficient. The preparation script is included
in the npm package; generated snapshots are not committed.

Both `defaultProvider` and `defaultModel` must be configured. Missing/partial,
unknown or custom defaults fail with fixed actionable errors; no arbitrary model
is chosen when defaults are absent. Existing `models.json`/`models.jsonc` causes
an explicit refusal rather than silently discarding endpoint/API overrides or
copying credential commands. The settings symlink is supported as before; only
validated provider/model strings are copied, never parent `ctx.model` or resource
settings. Selected catalog metadata must exist before spawning. Explicit
`--provider`/`--model` are passed and RPC `get_state.data.model` must match
provider, ID, API, context/output limits and compatibility/thinking capabilities
before **any** parent-managed room publication. Child-ready and RPC-ready may
arrive in either order; publication is single-flight. Startup authority is fenced
again before hello and signed auth, and failed/late publications are disposed.
Locked metadata remains working-only; no extra model IDs/thinking strings leak.

Reproduce source/dev and staged-release checks without another checkout:

```sh
PNPM_NATIVE=<existing-offline-native-pnpm> \
  pi-durable-subagents hold machine -- bash scripts/validate-managed-model.sh
```

The script prepares a missing snapshot before isolating HOME/USERPROFILE,
REMOTE_PI_HOME and PI_CODING_AGENT_DIR, clears worker/legacy child markers before
imports, and runs typecheck/build/tests without dependency verification/downloads.
Real CLI fixtures use synthetic credentials and a disconnected child network
namespace, issue `get_state` only (no model turn), and keep the signed loopback
parent proxy outside that namespace. They prove old0.79.10 fallback, modern Sol
capabilities and full managed preload/publication/control/fixture-Stop behavior.
No production relay, provider call, actual credentials or user process is needed.
