use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::response::Response;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::time::{self, Duration};
use tracing::{info, warn};

use crate::AppState;
use crate::auth::challenge::{
    HELLO_TIMEOUT_MS, challenge_line, gen_nonce, parse_hello, verify_auth,
};
use crate::protocol::outer::{OuterEnvelope, parse_line};
use crate::rooms::{RoomDisplay, RoomMeta, RoomMetaPatch};

/// Axum route handler: validates the WebSocket upgrade and hands the upgraded
/// socket to `handle_peer`, which owns the connection for its lifetime.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_peer(socket, addr, state))
}

/// Owns one peer's WebSocket connection: hello/challenge/auth → register →
/// routing loop (forwarding outer envelopes + handling presence/rooms control
/// frames + sending 25 s keepalive pings) → unregister on disconnect.
async fn handle_peer(socket: WebSocket, peer_addr: SocketAddr, state: AppState) {
    let peer_addr = peer_addr.to_string();
    let (mut sink, mut stream) = socket.split();

    // ── 1. Wait for hello (with timeout) ──────────────────────────────────
    let hello_result =
        tokio::time::timeout(Duration::from_millis(HELLO_TIMEOUT_MS), stream.next()).await;

    let hello_text = match hello_result {
        Ok(Some(Ok(Message::Text(t)))) => t,
        _ => {
            warn!(addr = %peer_addr, "no hello received, closing");
            return;
        }
    };

    let vk = match parse_hello(&hello_text) {
        Ok(vk) => vk,
        Err(e) => {
            warn!(addr = %peer_addr, err = %e, "bad hello, closing");
            return;
        }
    };

    // ── 2. Send challenge ─────────────────────────────────────────────────
    let (nonce, nonce_b64) = gen_nonce();
    if sink
        .send(Message::Text(challenge_line(&nonce_b64)))
        .await
        .is_err()
    {
        return;
    }

    // ── 3. Receive and verify auth ────────────────────────────────────────
    let auth_text = match stream.next().await {
        Some(Ok(Message::Text(t))) => t,
        _ => return,
    };

    if let Err(e) = verify_auth(&nonce, &vk, &auth_text) {
        warn!(addr = %peer_addr, err = %e, "auth failed, closing");
        let _ = sink.send(Message::Close(None)).await;
        return;
    }

    let peer_id = B64.encode(vk.to_bytes());
    let peer_short = peer_id[peer_id.len().saturating_sub(8)..].to_string();

    // Extract room_id and room_meta from hello (auth handled separately above).
    let hello = serde_json::from_str(&hello_text).unwrap_or(serde_json::Value::Null);
    let Some(room_meta) = room_meta_from_hello(&hello) else {
        warn!(peer = %peer_short, "invalid hello display metadata, closing");
        return;
    };
    let room_id = room_meta.room_id.clone();

    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "authenticated");

    let registry = state.registry.clone();
    let presence = state.presence.clone();
    let rooms = state.rooms.clone();
    let mesh = state.mesh.clone();
    let mesh_auth = state.mesh_auth.clone();
    let metrics = state.metrics.clone();

    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let conn_id = registry.register(peer_id.clone(), room_meta, tx).await;

    // Per-conn dedup state for control-frame replies. Suppress identical
    // re-emits of `presence` (single cache slot — there's only one
    // subscription set per conn) and `rooms` (one slot per target peer).
    let mut last_presence_resp: Option<String> = None;
    let mut last_rooms_resp: HashMap<String, String> = HashMap::new();

    // ── 4. Routing loop ───────────────────────────────────────────────────
    // Send a WS Ping every 25 s so NAT/LB idle timers don't close the connection.
    // First tick fires after 25 s (not immediately).
    let mut heartbeat = time::interval_at(
        time::Instant::now() + Duration::from_secs(25),
        Duration::from_secs(25),
    );

    'routing: loop {
        tokio::select! {
            item = stream.next() => {
                match item {
                    None | Some(Err(_)) => break,
                    Some(Ok(msg)) => {
                        let text = match msg {
                            Message::Text(t) => t,
                            Message::Close(_) => break,
                            // Pong frames are keepalive responses; Ping frames are
                            // answered automatically by axum's WS. Drop both.
                            Message::Ping(_) | Message::Pong(_) => continue,
                            Message::Binary(_) => continue, // ignore binary
                        };

                        // Parse as JSON to check for relay control frames.
                        let frame: serde_json::Value = match serde_json::from_str(&text) {
                            Ok(v) => v,
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid json, dropping");
                                continue;
                            }
                        };

                        // Frames with a top-level "type" are handled by the relay itself.
                        if let Some(t) = frame.get("type").and_then(|v| v.as_str()) {
                            let peers: Vec<String> = frame
                                .get("peers")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|v| v.as_str().map(String::from))
                                        .collect()
                                })
                                .unwrap_or_default();

                            match t {
                                // ── presence control frames (plano 12) ──
                                "subscribe_presence" => {
                                    presence.subscribe(peer_id.clone(), peers.clone()).await;
                                    // Backfill: push peer_online for any already-online
                                    // peers in the list, so subscribers don't have to
                                    // call presence_check to discover current state.
                                    registry.backfill_presence(&peer_id, &peers);
                                }
                                "unsubscribe_presence" => {
                                    presence.unsubscribe(&peer_id, peers).await;
                                }
                                "presence_check" => {
                                    let states = presence
                                        .snapshot(&peers, |p| registry.is_online(p))
                                        .await;
                                    let resp = serde_json::json!({
                                        "type": "presence",
                                        "states": states,
                                    })
                                    .to_string();
                                    // Dedup: skip reply if identical to the
                                    // previous one we sent on this conn. The
                                    // first reply always goes through (cache
                                    // is None until the first emit).
                                    if last_presence_resp.as_deref() == Some(resp.as_str()) {
                                        metrics.inc_presence_suppressed(1);
                                    } else {
                                        last_presence_resp = Some(resp.clone());
                                        if sink.send(Message::Text(resp)).await.is_err() {
                                            break;
                                        }
                                        metrics.inc_presence_emitted(1);
                                    }
                                }

                                // ── rooms control frames (plano 17) ──
                                "subscribe_rooms" => {
                                    rooms.subscribe(peer_id.clone(), peers).await;
                                }
                                "unsubscribe_rooms" => {
                                    rooms.unsubscribe(&peer_id, peers).await;
                                }
                                "rooms_check" => {
                                    if !registry.queue_rooms_check(
                                        &peer_id, &room_id, conn_id, &peers, &mut last_rooms_resp,
                                    ) {
                                        break 'routing;
                                    }
                                }

                                // ── room meta update (plano 18 + 28 + 32) ──
                                // `meta.model`, `meta.thinking` and
                                // `meta.working` are patched independently: a
                                // field absent from `meta` is *left alone* on
                                // the room (not cleared). For the nullable
                                // string fields, an explicit `null` clears
                                // them. `working` is a plain bool, so it only
                                // ever toggles — a non-bool/absent value leaves
                                // it untouched. Mirrors the JSON Merge Patch
                                // shape clients already produce.
                                "room_meta_update" => {
                                    let target_room = frame
                                        .get("room_id")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or(&room_id)
                                        .to_string();
                                    let Some(patch) = room_meta_patch(&frame) else {
                                        warn!(peer = %peer_short, "invalid display update metadata, dropping");
                                        continue;
                                    };
                                    if !registry
                                        .update_room_meta(&peer_id, &target_room, conn_id, patch)
                                        .await
                                    {
                                        warn!(
                                            peer = %peer_short,
                                            room = %target_room,
                                            "room_meta_update rejected, dropping"
                                        );
                                    }
                                }

                                // ── Pi-to-Pi envelope forward (plano 25 W-A) ──
                                "pi_envelope" => {
                                    use crate::handlers::pi_forward::{
                                        PiForwardResult, handle_pi_envelope,
                                    };
                                    match handle_pi_envelope(
                                        &peer_id,
                                        &frame,
                                        &registry,
                                        mesh.clone(),
                                        mesh_auth.clone(),
                                    )
                                    .await
                                    {
                                        PiForwardResult::Forwarded => {}
                                        PiForwardResult::TransportError(err_msg) => {
                                            if sink.send(err_msg).await.is_err() {
                                                break;
                                            }
                                        }
                                    }
                                }

                                _ => {
                                    warn!(
                                        peer = %peer_short,
                                        frame_type = %t,
                                        "unknown control frame type, dropping"
                                    );
                                }
                            }
                            continue; // do not fall through to envelope path
                        }

                        // No "type" field → outer envelope (opaque routing).
                        match parse_line(&text) {
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid envelope, dropping");
                            }
                            Ok(env) => {
                                let ct_len = env.ct.len();
                                let dest_peer = env.peer;
                                let dest_room = env.room;
                                let dest_tail =
                                    dest_peer[dest_peer.len().saturating_sub(8)..].to_string();
                                // Rewrite: recipient sees sender's peer_id + sender's room_id.
                                let rewritten = OuterEnvelope {
                                    peer: peer_id.clone(),
                                    room: room_id.clone(),
                                    ct: env.ct,
                                };
                                let fwd_line = serde_json::to_string(&rewritten)
                                    .expect("OuterEnvelope serialisation is infallible");
                                // Skip-sender: pass our own conn_id so multi-device
                                // Owners don't echo their own outbound messages.
                                if !registry.forward(
                                    &dest_peer,
                                    &dest_room,
                                    Message::Text(fwd_line),
                                    conn_id,
                                ) {
                                    warn!(
                                        from = %peer_short,
                                        dest = %dest_tail,
                                        room = %dest_room,
                                        bytes = ct_len,
                                        "dest (peer, room) not found, dropping",
                                    );
                                }
                            }
                        }
                    }
                }
            }
            result = rx.recv() => {
                match result {
                    Some(msg) => {
                        if sink.send(msg).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
            _ = heartbeat.tick() => {
                if sink.send(Message::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
        }
    }

    registry.unregister(&peer_id, &room_id, conn_id).await;
    rooms.unsubscribe_all(&peer_id).await;
    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "disconnected");
}

fn room_meta_from_hello(hello: &serde_json::Value) -> Option<RoomMeta> {
    let room_id = hello
        .get("room_id")
        .and_then(|v| v.as_str())
        .unwrap_or("main")
        .to_string();
    let room_meta_val = hello.get("room_meta");
    let name = room_meta_val
        .and_then(|m| m.get("name"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let cwd = room_meta_val
        .and_then(|m| m.get("cwd"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let model = room_meta_val
        .and_then(|m| m.get("model"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let thinking = room_meta_val
        .and_then(|m| m.get("thinking"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let working = room_meta_val
        .and_then(|m| m.get("working"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let display = match room_meta_val.and_then(|m| m.get("display")) {
        Some(value) => Some(RoomDisplay::from_value(value)?),
        None => None,
    };
    Some(RoomMeta {
        room_id,
        name,
        cwd,
        model,
        thinking,
        working,
        started_at,
        display,
    })
}

fn room_meta_patch(frame: &serde_json::Value) -> Option<RoomMetaPatch> {
    let meta = frame.get("meta").and_then(|v| v.as_object());
    let display = match meta.and_then(|m| m.get("display")) {
        Some(value) => Some(RoomDisplay::from_value(value)?),
        None => None,
    };
    Some(RoomMetaPatch {
        model: meta
            .and_then(|m| m.get("model"))
            .map(|v| v.as_str().map(String::from)),
        thinking: meta
            .and_then(|m| m.get("thinking"))
            .map(|v| v.as_str().map(String::from)),
        working: meta
            .and_then(|m| m.get("working"))
            .and_then(|v| v.as_bool()),
        display,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn producer_serialization_fixtures_parse_without_routing_rekey() {
        let fixtures: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/81-display-serialization.json"
        ))
        .unwrap();
        let frames: Vec<_> = fixtures
            .as_array()
            .unwrap()
            .iter()
            .map(|v| &v["frame"])
            .collect();
        let legacy = room_meta_from_hello(frames[0]).unwrap();
        assert!(legacy.display.is_none());
        let initial = room_meta_from_hello(frames[1]).unwrap();
        assert_eq!(initial.room_id, "0123456789ab");
        assert_eq!(initial.name.as_deref(), Some("routing-agent"));
        let display = initial.display.unwrap();
        assert_eq!(display.revision, 0);
        assert!(display.name.is_none());
        let rename = room_meta_patch(frames[2]).unwrap().display.unwrap();
        assert!(display.same_incarnation(&rename));
        assert_eq!(rename.revision, 1);
        assert_eq!(rename.name.as_deref(), Some("Pi · system"));
        let reset = room_meta_patch(frames[3]).unwrap().display.unwrap();
        assert_eq!(reset.revision, 2);
        assert!(reset.name.is_none());
        assert_eq!(
            room_meta_from_hello(frames[4]).unwrap().display,
            Some(reset)
        );
        let unrelated = room_meta_patch(frames[5]).unwrap();
        assert!(unrelated.display.is_none());
        assert_eq!(unrelated.working, Some(false));
    }

    #[test]
    fn invalid_display_hello_and_update_fail_closed_but_legacy_patch_semantics_remain() {
        for invalid in [
            serde_json::Value::Null,
            serde_json::json!({}),
            serde_json::json!("alias"),
        ] {
            assert!(
                room_meta_from_hello(&serde_json::json!({"room_meta": {"display": invalid}}))
                    .is_none()
            );
            assert!(
                room_meta_patch(
                    &serde_json::json!({"meta": {"display": invalid, "working": true}})
                )
                .is_none()
            );
        }
        let patch = room_meta_patch(
            &serde_json::json!({"meta": {"model": null, "thinking": "high", "working": null}}),
        )
        .unwrap();
        assert_eq!(patch.model, Some(None));
        assert_eq!(patch.thinking, Some(Some("high".into())));
        assert!(patch.working.is_none());
        assert!(patch.display.is_none());
        assert!(
            room_meta_patch(&serde_json::json!({"meta": {}}))
                .unwrap()
                .is_empty()
        );
        let hello = room_meta_from_hello(&serde_json::json!({})).unwrap();
        assert_eq!(hello.room_id, "main");
        assert!(!hello.working);
    }

    #[tokio::test]
    async fn producer_serialization_fixtures_round_trip_registry_snapshots_and_subscriber_frames() {
        use crate::{FirehoseMetrics, PeerRegistry, PresenceManager, RoomManager};
        use std::sync::Arc;
        let fixtures: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/81-display-serialization.json"
        ))
        .unwrap();
        let frames: Vec<_> = fixtures
            .as_array()
            .unwrap()
            .iter()
            .map(|v| &v["frame"])
            .collect();
        let rooms = Arc::new(RoomManager::new());
        let registry = PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            rooms.clone(),
            Arc::new(FirehoseMetrics::new()),
        );
        let (tx, mut rx) = mpsc::unbounded_channel();
        registry
            .register(
                "app".into(),
                room_meta_from_hello(&serde_json::json!({})).unwrap(),
                tx,
            )
            .await;
        rooms.subscribe("app".into(), vec!["pi".into()]).await;
        let initial = room_meta_from_hello(frames[1]).unwrap();
        let room = initial.room_id.clone();
        let (tx, _) = mpsc::unbounded_channel();
        let conn = registry.register("pi".into(), initial, tx).await;
        let announced: serde_json::Value =
            serde_json::from_str(rx.try_recv().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(announced["type"], "room_announced");
        assert_eq!(announced["display"], frames[1]["room_meta"]["display"]);
        for frame in [frames[2], frames[3], frames[5]] {
            assert!(
                registry
                    .update_room_meta("pi", &room, conn, room_meta_patch(frame).unwrap())
                    .await
            );
            let pushed: serde_json::Value =
                serde_json::from_str(rx.try_recv().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(pushed["type"], "room_meta_updated");
            let snapshot = serde_json::to_value(registry.rooms_of("pi")).unwrap();
            assert_eq!(pushed["meta"]["display"], snapshot[0]["display"]);
            assert_eq!(snapshot[0]["name"], "routing-agent");
            assert_eq!(snapshot[0]["room_id"], room);
            if let Some(display) = frame["meta"].get("display") {
                assert_eq!(&pushed["meta"]["display"], display);
            }
        }
        let (tx, _) = mpsc::unbounded_channel();
        let reconnect = registry
            .register("pi".into(), room_meta_from_hello(frames[4]).unwrap(), tx)
            .await;
        assert!(rx.try_recv().is_err());
        registry.unregister("pi", &room, conn).await;
        assert!(
            rx.try_recv().is_err(),
            "same cached identity is not a new room/presence edge"
        );
        assert_eq!(
            serde_json::to_value(registry.rooms_of("pi")).unwrap()[0]["display"],
            frames[4]["room_meta"]["display"]
        );
        registry.unregister("pi", &room, reconnect).await;
        let ended: serde_json::Value =
            serde_json::from_str(rx.try_recv().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(ended["type"], "room_ended");
        assert!(registry.rooms_of("pi").is_empty());
    }

    #[tokio::test]
    async fn rooms_check_cannot_overtake_pending_display_announcement_and_invalidation() {
        use crate::{FirehoseMetrics, PeerRegistry, PresenceManager, RoomManager};
        use std::sync::Arc;
        let fixtures: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/81-display-serialization.json"
        ))
        .unwrap();
        let initial = &fixtures[1]["frame"];
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let registry = PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            rooms.clone(),
            metrics.clone(),
        );
        let (tx, mut queued) = mpsc::unbounded_channel();
        let app_conn = registry
            .register(
                "app".into(),
                room_meta_from_hello(&serde_json::json!({})).unwrap(),
                tx,
            )
            .await;
        rooms.subscribe("app".into(), vec!["pi".into()]).await;
        let (tx, _) = mpsc::unbounded_channel();
        let old_conn = registry
            .register("pi".into(), room_meta_from_hello(initial).unwrap(), tx)
            .await;
        let mut competing = initial.clone();
        competing["room_meta"]["display"]["epoch"] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
        let (tx, _) = mpsc::unbounded_channel();
        registry
            .register("pi".into(), room_meta_from_hello(&competing).unwrap(), tx)
            .await;
        assert!(registry.rooms_of("pi")[0].display.is_none());
        // Exercise the same capture/dedup/enqueue call as the handler. A
        // ready incoming check cannot bypass the pending authority channel.
        let mut cache = HashMap::new();
        assert!(registry.queue_rooms_check("app", "main", app_conn, &["pi".into()], &mut cache));
        let mut delivered = Vec::new();
        while let Ok(message) = queued.try_recv() {
            delivered.push(
                serde_json::from_str::<serde_json::Value>(message.to_text().unwrap()).unwrap(),
            );
        }
        assert_eq!(
            delivered
                .iter()
                .map(|v| v["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["room_announced", "room_meta_updated", "rooms"],
            "a current snapshot must not overtake older queued authority frames"
        );
        assert!(delivered[2]["rooms"][0].get("display").is_none());
        registry
            .unregister("pi", initial["room_id"].as_str().unwrap(), old_conn)
            .await;
        assert!(registry.queue_rooms_check("app", "main", app_conn, &["pi".into()], &mut cache));
        let refresh: serde_json::Value =
            serde_json::from_str(queued.try_recv().unwrap().to_text().unwrap()).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_str(queued.try_recv().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(refresh["type"], "room_announced");
        assert_eq!(snapshot["type"], "rooms");
        assert_eq!(refresh["display"], competing["room_meta"]["display"]);
        assert_eq!(snapshot["rooms"][0]["display"], refresh["display"]);
        assert!(queued.try_recv().is_err());
    }
}
