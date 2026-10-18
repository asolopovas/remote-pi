# Exact-session stop (inner opaque-envelope protocol)

[Project index](../../README.md#project-map) · [Host extension guide](../README.md)

Related contracts: [launcher authority](secure-launcher.md), [phone workflow](../../SECURE-LAUNCH.md), [mobile integration](../../app/README.md) and [transport trust model](../../PROTOCOL.md).

Authenticated, currently paired Owners can query their assigned room:

```json
{"type":"session_control_status","id":"query","room_id":"assigned-room"}
{"type":"session_control_status_result","in_reply_to":"query","room_id":"assigned-room","can_stop":true,"token":"fresh-random-confirmation","reason":"Stopping this Pi also closes its managed children."}
{"type":"session_stop","id":"confirmation","room_id":"assigned-room","token":"fresh-random-confirmation"}
{"type":"session_stop_result","in_reply_to":"confirmation","room_id":"assigned-room","state":"requested"}
```

`can_stop:false` never includes a token. Locked managed rooms return the reason
`Unlock the launching host first.` Rejections use correlated `error` messages.
Requests/results reject unknown fields; IDs, rooms and tokens are nonempty,
control-free strings of at most 128 characters. No PID/path/environment/command
surface is exposed. These controls never enter model input or history.

Tokens are random 256-bit, valid for 30 seconds, single-use, and bounded to 256
pending capabilities. They capture Owner, channel/room and lifecycle authority.
Primary TUI sessions additionally capture the native SDK session ID and context;
replacement, reload, reconnect and revocation invalidate pending authority. Stop
acknowledges `requested` **before** guarded SDK `ctx.abort(); ctx.shutdown()`.
Root shutdown uses existing session cleanup, including its managed children.

Managed-room authority is the immutable owned launch record + actual child
object + unique per-launch room (not a transcript branch within that process).
It additionally requires current launcher grant/epoch and pairing. The parent
uses its existing bounded owned-child stop primitive; `stopped` is emitted only
after confirmed child exit and a final authorization check. Child exit cleanup
is deferred only during that stop so a best-effort response can be attempted.
No child-controlled target selection or new child IPC controls are added.

Delivery is best effort: an acknowledgement may be lost, or `requested` may be
followed by an SDK failure. Treat a timeout/disconnect as **unknown**, never
silently retry a consumed confirmation. A `requested` response is not proof of
exit; observe the process/room ending. No automatic retry is implemented.

Primary RPC/print/JSON sessions report unsupported. In cached Pi **0.79.10**,
RPC `ctx.shutdown()` merely sets a flag checked on the next RPC input; it cannot
reliably stop an idle externally controlled RPC process. The isolated real-Pi
smoke documents that SDK limitation with one synthetic subsequent `get_state`
command; production does not send such a command or substitute a transport.
Managed RPC children still use the parent's existing owned-process stop path.

## Managed session access and launching host

`session_control_status_result` may add these strict, optional fields (old hosts
may omit both):

```json
{"access":{"state":"expired","expires_at":1770000000000},"launching_host":{"room_id":"actual-root-room","launcher_id":"actual-launcher-incarnation"}}
```

`access` describes only the authenticated assigned Owner's grant on this launcher,
not machine-wide access. `unlocked` and `expired` carry the actual absolute grant
expiry; `locked` and `unavailable` carry `null`. Expired means a retained real
grant expired, never that a process is old. Lock/revoke clears grant evidence.
A denied capability has no Stop token. The five-minute TTL, per-launcher grant
isolation and 30-second, single-use Stop confirmation remain unchanged.

The parent takes `launching_host` from its actually published current root room
and launcher instance, not cwd, names, process IDs or room naming conventions.
Only the assigned paired Owner receives it, after the final captured
current/epoch/authority checks used for session controls. Locked room discovery
still publishes only the permitted working metadata, not model/transcript data.

The App uses this origin to open that exact launching host for explicit private
operator unlock, then returns to the captured live paired child and queries new
session controls. Parent unlock alone is not proof of child access. No old Stop
confirmation or PIN is replayed, no Stop is automatic, and no PIN is persisted.
Missing legacy origin requires explicit same-peer host selection; no aliases or
paths are treated as provenance, and no settled launch result is reconstructed
from the mutation-request journal. There is no added origin registry.

Host updates do **not** activate safely by reloading a root with running managed
children: root shutdown/reload tears them down. Leave existing user jobs alone.
The App's explicit legacy selection works without host reload; optional host
metadata becomes available on safely updated/new host sessions only.
