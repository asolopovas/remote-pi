# Room display snapshots over a legacy Relay

[Project index](../../README.md#project-map) · [Host extension guide](../README.md)

Integration owners: [mobile ingress](../../app/README.md), [host extension](../README.md) and [relay protocol](../../PROTOCOL.md). This contract owns display metadata only, not [session controls](session-control.md).

Display-only endpoint metadata, additive to the compatible Relay `room_meta` /
`room_meta_update` path. The existing Relay forwards `ct` opaquely; no invented
control forwarding, server upgrade, new room, pairing, alias or chat selection.

## Wire contract

App sends a normal envelope to **the paired PC and exact discovered live room**:

```json
{"peer":"<paired PC canonical Base64 key>","room":"<exact Pi routing room>","ct":"<base64 UTF-8 JSON>"}
```

Inner request (exact three fields):

```json
{"type":"room_display_request","id":"<fresh UUID>","room_id":"<same exact Pi routing room>"}
```

Legacy Relay rewrites `peer` to the authenticated App/Owner key and `room` to
**the App socket's registered room**. That incoming outer `room` is not the Pi
request body room. Extension looks up the sender in `_findKnownPeer`, never
creates/re-attaches a chat channel, and requires body `room_id` equal its own
current registered relay room. No SDK, model, history, replay or queue action.

Extension sends `{peer:<requester>,room:<requester registered room>,ct:<base64>}`.
Legacy Relay rewrites the delivered outer `peer` and `room` to **the authenticated
PC and its registered Pi room**. Reply inner (exact four fields):

```json
{"type":"room_display_snapshot","in_reply_to":"<exact request UUID>","room_id":"<Pi registered room>","display":{"native_session_id":"<UUID>","epoch":"<UUID>","revision":1,"name":"Desktop A"}}
```

`display` is the existing four-field `RoomDisplay` or **null**. Object `name:null`
is a verified manual-name reset, not unavailability. Whole `display:null` means
no currently verified adapter snapshot (no own candidate, CLI/query/UUID failure,
or verification still pending). Adapter snapshots are cached: requests perform
no CLI calls. Existing two-second UUID-sandwich adapter polling remains. A changed
SDK session ID, replaced adapter/epoch, session/relay generation, room, closed
socket, disposal, or known owner reconciliation during lookup drops the response.
No unsolicited endpoint traffic or subscription/watchers are added.

Types are intentionally outside the normal ClientMessage/ServerMessage unions.
Both endpoint types are excluded from PlainPeerChannel and per-owner chat routing;
the auto-listener reserves them before its active-owner/reconnect skip.

## Bounds and silent drops

- Request line at most 4096 UTF-8 bytes; decoded inner at most 1024 bytes.
- Canonical padded Base64 `ct` and 32-byte canonical padded Base64 sender key.
- UUID ID; exact field set; nonempty rooms at most 256 UTF-8 bytes with no controls,
  format/bidi controls or line separators. No cwd/title/focus ownership inference.
- Per requester `(peer, registered App room)`: one admitted request/second.
- Per Extension relay listener: eight/second, four concurrent pairing lookups,
  64 recent requester lanes and 64 nonces retained for ten seconds.
- Replayed retained UUIDs are dropped; clients must generate a fresh nonce.
  A response after three seconds is dropped. A hung storage lookup retains its
  concurrency slot until it settles; no timeout-triggered backlog/retry.
- Invalid/unpaired/wrong-room/reserved snapshot traffic: consume and silently
  drop, never an `unknown_peer` chat error, name echo, transcript or body/key log.
- Listener teardown disposes its maps and revokes async authority. No timers
  or response queues in the endpoint. Transport errors are best-effort drops.

## Required App ingress rules

1. Send only to existing paired subscriptions and exact discovered **live** rooms,
   even if unselected. Do not use `session_sync` or attach/open chat to query.
   Use a small bounded cadence (e.g. >=2 seconds per room), bounded outstanding
   nonces and an expiry <=3 seconds; no offline send queue or alias persistence.
2. Reserve snapshots in the raw envelope ingress **before** normal active-chat
   routing, history mapping, session selection or transcript persistence.
3. Require current socket/paired-membership/live-room-start generation, a live
   pending fresh nonce bound to that exact PC+room, authenticated outer `peer`
   equal the paired PC, and nonempty outer `room` equal both expected room and
   body `room_id`. Do not treat body `room_id` alone as sender authority.
4. Reject malformed/oversized bodies, invalid native/epoch UUIDs, unsafe/negative
   revisions and invalid names using existing whole-object RoomDisplay validation.
   Consume the pending nonce once; late, conflicting or duplicate responses
   cannot re-arm a retired incarnation. No data is echoed into transcript.
5. Apply existing native/epoch retirement and revision high-water/conflict rules.
   Object `name:null` resets the verified name; whole null removes endpoint name
   authority, not membership or routing. Never persist either as a saved alias.
   Explicit canonical Relay invalidation must not be overridden by this fallback.
6. Discard pending endpoint requests/authority on disconnect, room removal/start
   replacement or membership replacement. Compatible Relay display controls keep
   their existing authority/validation. Endpoint snapshots do **not** certify
   transcript freshness, ownership from cwd, or historical session identity.

## Fixtures / focused proof

[Wire fixture](../test/fixtures/81-room-display-endpoint.json)
contains readable inner bodies and exact delivered Base64 wire envelopes. The
three responses are **alternative outcomes** for one nonce, not repeated replies.
Keys and UUIDs are synthetic constants, not real device identities.

- `src/transport/room_display_endpoint.test.ts`: strict validation, bounds,
  nonactive owner, active-channel exclusion, async retirement and faithful legacy
  destination/registered-sender rewrite with two duplicate-cwd distinct rooms.
- `src/extension.test.ts` suite `UUID-scoped room display producer`: real index
  boundary with mocked relay/storage/CLI; no attach/replay/SDK/reconnect side
  effects, native/session teardown, nonce correlated rename/reset/unavailable.
- `src/session/tuios_display.test.ts`: native UUID sandwich, revision/epoch,
  verified reset vs unavailable, child exclusion and query cancellation.

Legacy forwarding fixture is faithful to pre-feature `relay/src/handlers/peer.rs`
(`git show e5c6edf7^:relay/src/handlers/peer.rs`, envelope rewrite around 348–352).
It is local evidence only; live forwarding and physical-phone rename acceptance
remain the parent/integration owner's gates, not performed by this component.
