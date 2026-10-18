use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::ws::Message;
use tokio::sync::mpsc;

use crate::metrics::FirehoseMetrics;
use crate::presence::PresenceManager;
use crate::rooms::{RoomDisplay, RoomManager, RoomMeta, RoomMetaPatch};

type RoomKey = (String, String); // (peer_id, room_id)
type ConnEntry = (u64, RoomMeta, mpsc::UnboundedSender<Message>);

const MAX_DISPLAY_INCARNATIONS: usize = 64;

#[derive(Debug)]
struct DisplayHighWater {
    display: RoomDisplay,
    conflicted: bool,
}

#[derive(Debug, Default)]
struct RoomConnections {
    entries: Vec<ConnEntry>,
    /// Metadata only, retained until the routing room's last connection leaves.
    /// Never copied to a connection or served as a disconnected alias.
    display_high_water: HashMap<(String, String), DisplayHighWater>,
    display_overflowed: bool,
}

impl RoomConnections {
    fn observe_display(&mut self, display: &RoomDisplay) {
        let key = (display.native_session_id.clone(), display.epoch.clone());
        if let Some(water) = self.display_high_water.get_mut(&key) {
            if display.revision > water.display.revision {
                water.display = display.clone();
                water.conflicted = false;
            } else if display.revision == water.display.revision
                && display.name != water.display.name
            {
                water.conflicted = true;
            }
        } else if self.display_high_water.len() < MAX_DISPLAY_INCARNATIONS {
            self.display_high_water.insert(
                key,
                DisplayHighWater {
                    display: display.clone(),
                    conflicted: false,
                },
            );
        } else {
            // Do not evict a fence and thereby re-admit an old alias.
            self.display_overflowed = true;
        }
    }

    fn aggregate_display(&self) -> Option<RoomDisplay> {
        if self.display_overflowed {
            return None;
        }
        let mut highest: Option<&RoomDisplay> = None;
        for (_, meta, _) in &self.entries {
            let display = meta.display.as_ref()?; // unbound legacy conn is ambiguous
            if let Some(current) = highest {
                if !current.same_incarnation(display) {
                    return None;
                }
                if display.revision > current.revision {
                    highest = Some(display);
                }
            } else {
                highest = Some(display);
            }
        }
        let highest = highest?;
        let water = self
            .display_high_water
            .get(&(highest.native_session_id.clone(), highest.epoch.clone()))?;
        if water.conflicted || highest != &water.display {
            return None;
        }
        Some(highest.clone())
    }

    fn snapshot(&self) -> Option<RoomMeta> {
        let mut meta = self.entries.last()?.1.clone();
        // Only the unrelated legacy fields keep their historical last-conn rule.
        meta.display = self.aggregate_display();
        Some(meta)
    }

    fn accept_display(&mut self, conn_id: u64, display: &RoomDisplay) -> bool {
        if self.entries.iter().any(|(_, meta, _)| {
            meta.display.as_ref().is_some_and(|other| {
                other.same_incarnation(display)
                    && other.revision == display.revision
                    && other.name != display.name
            })
        }) {
            return false;
        }
        let Some((_, meta, _)) = self.entries.iter_mut().find(|(cid, _, _)| *cid == conn_id) else {
            return false;
        };
        let Some(advertised) = &meta.display else {
            return false;
        };
        if !advertised.same_incarnation(display) || display.revision <= advertised.revision {
            return false;
        }
        if let Some(water) = self
            .display_high_water
            .get(&(display.native_session_id.clone(), display.epoch.clone()))
            && display.revision == water.display.revision
            && (water.conflicted || display.name != water.display.name)
        {
            return false;
        }
        meta.display = Some(display.clone());
        self.observe_display(display);
        true
    }
}

/// Maps `(peer_id, room_id)` pairs to a *list* of live connections.
///
/// Plan 23 (Wave 2C) relaxed the "one connection per (peer, room)" invariant:
/// the registry now accepts N simultaneous connections at the same key —
/// representing N devices of the same human Owner (shared Ed25519 key
/// sincronizada via iCloud Keychain / Block Store). Each device authenticates
/// independently via challenge-response, so admission is still controlled by
/// possession of the private key.
///
/// When another peer forwards a message to `(owner_pk, room_id)`, every live
/// conn in the corresponding `Vec` receives a copy. The originating connection
/// skips itself via `from_conn_id`, so a multi-device app sees outgoing
/// messages only on the device that sent them.
///
/// Lifecycle events:
/// - `room_announced` opens a room, or refreshes display-incarnation authority
///   within the same room. Refreshes never create presence/room lifecycle edges.
/// - `room_ended` fires once, when the *last* conn at a room disconnects.
/// - `peer_online` fires only on a real **offline → online** transition: when
///   the peer had **zero** live conns immediately before this register. A
///   second/third conn from the same peer is silently absorbed (no extra
///   `peer_online` for subscribers). The historic "ALWAYS fires" defense
///   against zombie conns was retired here because (a) clients now dedupe
///   client-side anyway and (b) it was generating a firehose of identical
///   frames whenever multiple Owner devices reconnected.
///
///   Zombie reasoning: if a phantom conn is still in the map, `was_offline ==
///   false` and we skip the emit — subscribers already think the peer is
///   online (which is still effectively true at the public protocol level).
///   When the zombie is finally cleaned, `unregister` only fires
///   `peer_offline` if the **whole** peer is gone — never wrongly while a
///   real conn is alive.
/// - `peer_offline` fires only when the peer transitions from N → 0 total
///   connections (asymmetric still: online and offline both gated by real
///   state changes, but the offline edge is the authoritative one).
#[derive(Debug)]
pub struct PeerRegistry {
    next_conn: AtomicU64,
    senders: Mutex<HashMap<RoomKey, RoomConnections>>,
    presence: Arc<PresenceManager>,
    rooms: Arc<RoomManager>,
    metrics: Arc<FirehoseMetrics>,
}

impl PeerRegistry {
    pub fn new(
        presence: Arc<PresenceManager>,
        rooms: Arc<RoomManager>,
        metrics: Arc<FirehoseMetrics>,
    ) -> Self {
        Self {
            next_conn: AtomicU64::new(0),
            senders: Mutex::new(HashMap::new()),
            presence,
            rooms,
            metrics,
        }
    }

    /// Registers a new connection at `(peer_id, room_meta.room_id)`.
    ///
    /// Multiple connections may coexist at the same key — each gets a unique
    /// `conn_id`. Display-authority changes refresh the existing room without
    /// changing its lifecycle. `peer_online` fires only
    /// when `was_offline_before == true` — i.e. on a real offline→online
    /// transition, not on every register. See struct-level docs.
    pub async fn register(
        &self,
        peer_id: String,
        room_meta: RoomMeta,
        tx: mpsc::UnboundedSender<Message>,
    ) -> u64 {
        let room_id = room_meta.room_id.clone();
        let key = (peer_id.clone(), room_id.clone());

        let conn_id = self.next_conn.fetch_add(1, Ordering::Relaxed);

        // Hold subscription membership through mutation/enqueue so a new
        // subscriber cannot check old state and miss the following push.
        let was_offline_before = self
            .rooms
            .with_subscribers(&peer_id, |room_subs| {
                let mut lock = self.senders.lock().unwrap();
                let was_offline_before = !lock.keys().any(|(p, _)| p == &peer_id);
                let is_first_in_room = !lock.contains_key(&key);
                let room = lock.entry(key).or_default();
                let before_display = room.aggregate_display();
                if let Some(display) = &room_meta.display {
                    room.observe_display(display);
                }
                room.entries.push((conn_id, room_meta, tx));
                let frame = room.snapshot().and_then(|snapshot| {
                    if is_first_in_room {
                        announced_frame(&peer_id, &snapshot)
                    } else {
                        display_transition_frame(&peer_id, before_display.as_ref(), &snapshot)
                    }
                });
                queue_room_frame_locked(&lock, &room_subs, frame);
                was_offline_before
            })
            .await;

        // peer_online fires only on a real offline → online transition.
        // Re-registers from a peer that already had a live conn produce no
        // new push to subscribers — they already think it's online.
        let pres_subs = self.presence.subscribers_of(&peer_id).await;
        let sub_count = pres_subs.len() as u64;
        if sub_count > 0 {
            if was_offline_before {
                let msg = serde_json::json!({"type": "peer_online", "peer": peer_id}).to_string();
                for sub in pres_subs {
                    self.forward_to_all_rooms_of(&sub, Message::Text(msg.clone()));
                }
                self.metrics.inc_peer_online_emitted(sub_count);
            } else {
                self.metrics.inc_peer_online_suppressed(sub_count);
            }
        }

        conn_id
    }

    /// Immediately pushes a `peer_online` to `subscriber` for every peer in
    /// `peers` that is currently online. Called by the handler right after
    /// `subscribe_presence` to bridge the gap when a peer subscribed *after*
    /// its target was already connected.
    pub fn backfill_presence(&self, subscriber: &str, peers: &[String]) {
        for peer in peers {
            if self.is_online(peer) {
                let msg = serde_json::json!({"type": "peer_online", "peer": peer}).to_string();
                self.forward_to_all_rooms_of(subscriber, Message::Text(msg));
            }
        }
    }

    /// Removes the connection identified by `conn_id` from the `Vec` at
    /// `(peer_id, room_id)`. When the `Vec` empties, the entry is removed and
    /// `room_ended` is broadcast; when the peer has no remaining rooms,
    /// `peer_offline` is also broadcast.
    ///
    /// Stale `conn_id`s (already removed, or never registered there) are no-ops.
    pub async fn unregister(&self, peer_id: &str, room_id: &str, conn_id: u64) {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;

        let peer_offlined = self
            .rooms
            .with_subscribers(peer_id, |room_subs| {
                let mut lock = self.senders.lock().unwrap();
                let key = (peer_id.to_string(), room_id.to_string());
                let mut room_emptied = false;
                let mut frame = None;
                if let Some(room) = lock.get_mut(&key) {
                    let before_display = room.aggregate_display();
                    let before = room.entries.len();
                    room.entries.retain(|(cid, _, _)| *cid != conn_id);
                    let removed_something = room.entries.len() != before;
                    if room.entries.is_empty() {
                        lock.remove(&key); // also drops the display ledger
                        room_emptied = removed_something;
                    } else if removed_something {
                        frame = room.snapshot().and_then(|snapshot| {
                            display_transition_frame(peer_id, before_display.as_ref(), &snapshot)
                        });
                    }
                }
                if room_emptied {
                    frame = Some(serde_json::json!({
                        "type": "room_ended", "peer": peer_id,
                        "room_id": room_id, "since_ts": now_ms,
                    }));
                }
                queue_room_frame_locked(&lock, &room_subs, frame);
                room_emptied && !lock.keys().any(|(p, _)| p == peer_id)
            })
            .await;

        if peer_offlined {
            let pres_subs = self.presence.subscribers_of(peer_id).await;
            if !pres_subs.is_empty() {
                let msg = serde_json::json!({
                    "type": "peer_offline",
                    "peer": peer_id,
                    "since_ts": now_ms,
                })
                .to_string();
                for sub in pres_subs {
                    self.forward_to_all_rooms_of(&sub, Message::Text(msg.clone()));
                }
            }
            self.presence.record_offline(peer_id, now_ms).await;
            self.presence.unsubscribe_all(peer_id).await;
        }
    }

    /// Returns `true` if `peer_id` has at least one live connection.
    pub fn is_online(&self, peer_id: &str) -> bool {
        let lock = self.senders.lock().unwrap();
        lock.keys().any(|(p, _)| p == peer_id)
    }

    /// Returns one snapshot per routing room, using the same display authority
    /// and ambiguity/freshness rules as lifecycle and metadata broadcasts.
    pub fn rooms_of(&self, peer_id: &str) -> Vec<RoomMeta> {
        let lock = self.senders.lock().unwrap();
        rooms_of_locked(&lock, peer_id)
    }

    /// Snapshot, dedup and enqueue share the authority-push linearization.
    /// Only the requesting registered connection receives the reply; all room
    /// output reaches its socket through the same FIFO channel.
    pub fn queue_rooms_check(
        &self,
        requesting_peer: &str,
        requesting_room: &str,
        conn_id: u64,
        peers: &[String],
        last_rooms_resp: &mut HashMap<String, String>,
    ) -> bool {
        let Ok(lock) = self.senders.lock() else {
            return false;
        };
        let key = (requesting_peer.to_string(), requesting_room.to_string());
        let Some((_, _, tx)) = lock
            .get(&key)
            .and_then(|room| room.entries.iter().find(|(cid, _, _)| *cid == conn_id))
        else {
            return false;
        };
        for peer in peers {
            let resp = serde_json::json!({
                "type": "rooms", "peer": peer, "rooms": rooms_of_locked(&lock, peer),
            })
            .to_string();
            if last_rooms_resp.get(peer) == Some(&resp) {
                self.metrics.inc_rooms_suppressed(1);
                continue;
            }
            if tx.send(Message::Text(resp.clone())).is_err() {
                return false;
            }
            last_rooms_resp.insert(peer.clone(), resp);
            self.metrics.inc_rooms_emitted(1);
        }
        true
    }

    /// Broadcasts `msg` to every live connection at `(dest_peer, dest_room)`
    /// **except** the one whose conn_id equals `from_conn_id` (skip-sender).
    ///
    /// Returns `true` if at least one recipient received the message.
    /// Pass any `from_conn_id` that is not part of the destination `Vec`
    /// (e.g. the sender's own conn_id from another room) to deliver to all.
    /// Never inspects message content.
    pub fn forward(
        &self,
        dest_peer: &str,
        dest_room: &str,
        msg: Message,
        from_conn_id: u64,
    ) -> bool {
        let lock = self.senders.lock().unwrap();
        let key = (dest_peer.to_string(), dest_room.to_string());
        let Some(v) = lock.get(&key) else {
            return false;
        };
        let mut delivered = false;
        for (cid, _, tx) in &v.entries {
            if *cid == from_conn_id {
                continue;
            }
            if tx.send(msg.clone()).is_ok() {
                delivered = true;
            }
        }
        delivered
    }

    /// Legacy model/thinking/working patches still apply to all room connections.
    /// Display patches affect only conn_id at this key, and must advance that
    /// connection's hello-advertised incarnation. Invalid display rejects the
    /// entire patch before any metadata changes.
    pub async fn update_room_meta(
        &self,
        peer_id: &str,
        room_id: &str,
        conn_id: u64,
        patch: RoomMetaPatch,
    ) -> bool {
        self.rooms
            .with_subscribers(peer_id, |room_subs| {
                let mut lock = self.senders.lock().unwrap();
                let key = (peer_id.to_string(), room_id.to_string());
                let Some(room) = lock.get_mut(&key) else {
                    return false;
                };
                let before_display = room.aggregate_display();
                if let Some(display) = &patch.display
                    && !room.accept_display(conn_id, display)
                {
                    return false;
                }
                for (_, meta, _) in &mut room.entries {
                    if let Some(m) = &patch.model {
                        meta.model = m.clone();
                    }
                    if let Some(t) = &patch.thinking {
                        meta.thinking = t.clone();
                    }
                    if let Some(w) = patch.working {
                        meta.working = w;
                    }
                }
                if !patch.is_empty() {
                    let frame = room.snapshot().and_then(|snapshot| {
                        if new_display_incarnation(
                            before_display.as_ref(),
                            snapshot.display.as_ref(),
                        ) {
                            announced_frame(peer_id, &snapshot)
                        } else {
                            meta_frame(peer_id, &snapshot)
                        }
                    });
                    queue_room_frame_locked(&lock, &room_subs, frame);
                }
                true
            })
            .await
    }

    /// Sends `msg` to every live connection of `peer_id` across all rooms.
    /// Used for control-frame pushes (`peer_online`/`peer_offline`,
    /// `room_announced`/`room_ended`, `room_meta_updated`) where the
    /// subscriber's room isn't known in advance.
    fn forward_to_all_rooms_of(&self, peer_id: &str, msg: Message) {
        let lock = self.senders.lock().unwrap();
        for ((p, _), v) in lock.iter() {
            if p == peer_id {
                for (_, _, tx) in &v.entries {
                    let _ = tx.send(msg.clone());
                }
            }
        }
    }

    /// Sends `msg` to every live connection of `peer_id`, regardless of room.
    /// Returns `true` iff at least one recipient successfully accepted it.
    /// Used by `pi_envelope` cross-PC forwarding (plan 25) where the relay
    /// has Pi-B's pubkey but not its room_id.
    pub fn forward_to_peer(&self, peer_id: &str, msg: Message) -> bool {
        let lock = self.senders.lock().unwrap();
        let mut delivered = false;
        for ((p, _), v) in lock.iter() {
            if p == peer_id {
                for (_, _, tx) in &v.entries {
                    if tx.send(msg.clone()).is_ok() {
                        delivered = true;
                    }
                }
            }
        }
        delivered
    }
}

fn rooms_of_locked(senders: &HashMap<RoomKey, RoomConnections>, peer_id: &str) -> Vec<RoomMeta> {
    senders
        .iter()
        .filter(|((peer, _), _)| peer == peer_id)
        .filter_map(|(_, room)| room.snapshot())
        .collect()
}

/// Enqueue only: caller holds senders, so no recursive lock/await/network I/O.
fn queue_room_frame_locked(
    senders: &HashMap<RoomKey, RoomConnections>,
    subscribers: &[String],
    frame: Option<serde_json::Value>,
) {
    let Some(frame) = frame else {
        return;
    };
    let msg = Message::Text(frame.to_string());
    for ((peer, _), room) in senders {
        if subscribers.contains(peer) {
            for (_, _, tx) in &room.entries {
                let _ = tx.send(msg.clone());
            }
        }
    }
}

fn announced_frame(peer_id: &str, snapshot: &RoomMeta) -> Option<serde_json::Value> {
    let mut announced = serde_json::to_value(snapshot).ok()?;
    announced["type"] = "room_announced".into();
    announced["peer"] = peer_id.into();
    Some(announced)
}

fn meta_frame(peer_id: &str, snapshot: &RoomMeta) -> Option<serde_json::Value> {
    let mut meta = serde_json::Map::new();
    if let Some(model) = &snapshot.model {
        meta.insert("model".into(), model.clone().into());
    }
    if let Some(thinking) = &snapshot.thinking {
        meta.insert("thinking".into(), thinking.clone().into());
    }
    meta.insert("working".into(), snapshot.working.into());
    // Explicit null invalidates authority; object name:null is verified reset.
    meta.insert(
        "display".into(),
        serde_json::to_value(&snapshot.display).ok()?,
    );
    Some(serde_json::json!({
        "type": "room_meta_updated", "peer": peer_id,
        "room_id": snapshot.room_id, "meta": meta,
    }))
}

fn display_transition_frame(
    peer_id: &str,
    before: Option<&RoomDisplay>,
    snapshot: &RoomMeta,
) -> Option<serde_json::Value> {
    if before == snapshot.display.as_ref() {
        return None;
    }
    if new_display_incarnation(before, snapshot.display.as_ref()) {
        announced_frame(peer_id, snapshot)
    } else {
        meta_frame(peer_id, snapshot)
    }
}

fn new_display_incarnation(before: Option<&RoomDisplay>, after: Option<&RoomDisplay>) -> bool {
    after.is_some_and(|after| before.is_none_or(|before| !before.same_incarnation(after)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::presence::PresenceManager;
    use crate::rooms::{RoomManager, RoomMeta};

    fn make_meta(room_id: &str) -> RoomMeta {
        RoomMeta {
            room_id: room_id.into(),
            name: None,
            cwd: None,
            model: None,
            thinking: None,
            working: false,
            display: None,
            started_at: 0,
        }
    }

    fn make_registry() -> PeerRegistry {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        PeerRegistry::new(presence, rooms, metrics)
    }

    /// Sentinel `from_conn_id` for "no real sender to skip" — guaranteed not
    /// to collide with any conn_id allocated by the registry in tests.
    const EXTERNAL: u64 = u64::MAX;

    #[tokio::test]
    async fn two_rooms_same_peer_both_accepted() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx_main, mut rx_main) = mpsc::unbounded_channel::<Message>();
        let (tx_work, mut rx_work) = mpsc::unbounded_channel::<Message>();

        let conn_main = reg.register(peer.clone(), make_meta("main"), tx_main).await;
        let conn_work = reg.register(peer.clone(), make_meta("work"), tx_work).await;

        assert_ne!(conn_main, conn_work);

        assert!(reg.forward(&peer, "main", Message::Text("to_main".into()), EXTERNAL));
        assert_eq!(rx_main.try_recv().unwrap().to_text().unwrap(), "to_main");

        assert!(reg.forward(&peer, "work", Message::Text("to_work".into()), EXTERNAL));
        assert_eq!(rx_work.try_recv().unwrap().to_text().unwrap(), "to_work");

        reg.unregister(&peer, "work", conn_work).await;
        assert!(!reg.forward(&peer, "work", Message::Text("gone".into()), EXTERNAL));
        assert!(reg.forward(&peer, "main", Message::Text("still_there".into()), EXTERNAL));
        let _ = rx_main.try_recv();
    }

    /// Two conns at the same (peer, room) now coexist. `forward` with the first
    /// conn's id as `from_conn_id` delivers only to the second (skip-sender).
    #[tokio::test]
    async fn duplicate_room_accepted_and_broadcast() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();

        let conn1 = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let conn2 = reg.register(peer.clone(), make_meta("main"), tx2).await;
        assert_ne!(conn1, conn2);

        // Send "from" conn1 → only conn2 receives.
        assert!(reg.forward(&peer, "main", Message::Text("hi".into()), conn1));
        assert!(rx1.try_recv().is_err(), "sender must not echo");
        assert_eq!(rx2.try_recv().unwrap().to_text().unwrap(), "hi");

        // Send "from" conn2 → only conn1 receives.
        assert!(reg.forward(&peer, "main", Message::Text("hi2".into()), conn2));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "hi2");
        assert!(rx2.try_recv().is_err());
    }

    /// Three conns at same (peer, room); one disconnects; remaining two keep
    /// receiving broadcasts from external senders.
    #[tokio::test]
    async fn three_conns_one_disconnects_broadcast_continues() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();
        let (tx3, mut rx3) = mpsc::unbounded_channel::<Message>();

        let _conn1 = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let conn2 = reg.register(peer.clone(), make_meta("main"), tx2).await;
        let _conn3 = reg.register(peer.clone(), make_meta("main"), tx3).await;

        reg.unregister(&peer, "main", conn2).await;

        assert!(reg.forward(&peer, "main", Message::Text("ping".into()), EXTERNAL));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "ping");
        assert!(
            rx2.try_recv().is_err(),
            "disconnected conn must not receive"
        );
        assert_eq!(rx3.try_recv().unwrap().to_text().unwrap(), "ping");
    }

    /// `from_conn_id` outside the destination Vec → all conns at that pair
    /// receive. Models the common "another peer sends to (owner_pk, main)" case.
    #[tokio::test]
    async fn forward_with_unknown_from_conn_id_reaches_all() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();

        let _ = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let _ = reg.register(peer.clone(), make_meta("main"), tx2).await;

        assert!(reg.forward(&peer, "main", Message::Text("from_pi".into()), EXTERNAL));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "from_pi");
        assert_eq!(rx2.try_recv().unwrap().to_text().unwrap(), "from_pi");
    }

    /// Single-conn case: skip-sender with own id → nobody receives.
    /// External sender → that single conn receives.
    #[tokio::test]
    async fn single_conn_skip_sender() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let conn = reg.register(peer.clone(), make_meta("main"), tx).await;

        assert!(!reg.forward(&peer, "main", Message::Text("echo".into()), conn));
        assert!(rx.try_recv().is_err());

        assert!(reg.forward(&peer, "main", Message::Text("hi".into()), EXTERNAL));
        assert_eq!(rx.try_recv().unwrap().to_text().unwrap(), "hi");
    }

    /// Re-calling `unregister` with a stale `conn_id` does not affect any
    /// other live conn at the same key.
    #[tokio::test]
    async fn stale_unregister_is_noop() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx_a, _) = mpsc::unbounded_channel::<Message>();
        let (tx_b, mut rx_b) = mpsc::unbounded_channel::<Message>();

        let conn_a = reg.register(peer.clone(), make_meta("main"), tx_a).await;
        reg.unregister(&peer, "main", conn_a).await;
        let conn_b = reg.register(peer.clone(), make_meta("main"), tx_b).await;

        // Stale unregister of conn_a is a no-op.
        reg.unregister(&peer, "main", conn_a).await;
        assert!(reg.forward(&peer, "main", Message::Text("alive".into()), EXTERNAL));
        assert_eq!(rx_b.try_recv().unwrap().to_text().unwrap(), "alive");

        // Correct unregister removes the last conn → entry gone.
        reg.unregister(&peer, "main", conn_b).await;
        assert!(!reg.forward(&peer, "main", Message::Text("gone".into()), EXTERNAL));
    }

    /// First register from an offline peer with a presence subscriber must
    /// emit one `peer_online`; a second register from the **same** peer (no
    /// real transition) must NOT emit again and must bump the suppressed
    /// counter instead.
    #[tokio::test]
    async fn peer_online_fires_only_on_real_transition() {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let reg = PeerRegistry::new(presence.clone(), rooms, metrics.clone());

        let pi = "pi".to_string();
        let app = "app".to_string();

        // App is online and subscribes to Pi's presence.
        let (tx_app, mut rx_app) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(app.clone(), make_meta("main"), tx_app).await;
        presence.subscribe(app.clone(), vec![pi.clone()]).await;

        // First Pi conn → real offline→online → app receives peer_online.
        let (tx_pi_1, _) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("main"), tx_pi_1).await;
        let m1 = rx_app.try_recv().unwrap();
        let v1: serde_json::Value = serde_json::from_str(m1.to_text().unwrap()).unwrap();
        assert_eq!(v1["type"], "peer_online");
        assert_eq!(v1["peer"], pi.clone());

        // Second conn from the same Pi (no transition) → no extra peer_online.
        let (tx_pi_2, _) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("work"), tx_pi_2).await;
        assert!(
            rx_app.try_recv().is_err(),
            "second register at already-online peer must NOT emit peer_online"
        );

        // Metrics: 1 emitted, 1 suppressed (each over 1 subscriber).
        let [emitted, suppressed, ..] = metrics.snapshot();
        assert_eq!(emitted, 1, "snapshot: {:?}", metrics.snapshot());
        assert_eq!(suppressed, 1, "snapshot: {:?}", metrics.snapshot());
    }

    /// Helper: a Pi with one `main` room plus an `app` subscribed to that
    /// peer's room events. Returns the registry, the shared `rooms` handle,
    /// the peer ids, and the app's receiver (drained of any backfill).
    async fn meta_fixture() -> (PeerRegistry, String, mpsc::UnboundedReceiver<Message>) {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let reg = PeerRegistry::new(presence, rooms.clone(), metrics);

        let pi = "pi".to_string();
        let app = "app".to_string();

        // Pi registers first, *before* the app subscribes — so the app gets no
        // `room_announced` backfill and its channel only carries the
        // `room_meta_updated` pushes the tests assert on.
        let (tx_pi, _rx_pi) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("main"), tx_pi).await;

        let (tx_app, rx_app) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(app.clone(), make_meta("main"), tx_app).await;
        rooms.subscribe(app.clone(), vec![pi.clone()]).await;

        (reg, pi, rx_app)
    }

    fn recv_meta(rx: &mut mpsc::UnboundedReceiver<Message>) -> serde_json::Value {
        let msg = rx
            .try_recv()
            .expect("subscriber must receive room_meta_updated");
        let v: serde_json::Value = serde_json::from_str(msg.to_text().unwrap()).unwrap();
        assert_eq!(v["type"], "room_meta_updated");
        v
    }

    /// `working: true` patch broadcasts the post-patch state to subscribers.
    #[tokio::test]
    async fn working_true_patch_broadcasts_true() {
        let (reg, pi, mut rx_app) = meta_fixture().await;

        let patch = RoomMetaPatch {
            working: Some(true),
            ..Default::default()
        };
        assert!(reg.update_room_meta(&pi, "main", 0, patch).await);

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["peer"], pi);
        assert_eq!(v["room_id"], "main");
        assert_eq!(v["meta"]["working"], true);
    }

    /// `working: false` patch is a real (non-empty) patch and broadcasts
    /// `working: false` — flipping a previously-true room back off.
    #[tokio::test]
    async fn working_false_patch_broadcasts_false() {
        let (reg, pi, mut rx_app) = meta_fixture().await;

        // Turn it on, then off.
        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                0,
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                0,
                RoomMetaPatch {
                    working: Some(false),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], false);
    }

    /// A patch that omits `working` (e.g. a model-only update) must NOT zero a
    /// previously-set `working: true` — merge-patch absence leaves it intact,
    /// and the broadcast re-carries the preserved value.
    #[tokio::test]
    async fn working_absent_patch_does_not_zero() {
        let (reg, pi, mut rx_app) = meta_fixture().await;

        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                0,
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        // Model-only patch: `working` is absent → must be left untouched.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                0,
                RoomMetaPatch {
                    model: Some(Some("opus".into())),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["model"], "opus");
        assert_eq!(
            v["meta"]["working"], true,
            "absent `working` in a patch must not clear it"
        );
    }

    fn display(revision: u64, name: Option<&str>) -> crate::rooms::RoomDisplay {
        crate::rooms::RoomDisplay::from_value(&serde_json::json!({
            "native_session_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "epoch": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "revision": revision, "name": name,
        }))
        .unwrap()
    }

    async fn display_fixture() -> (PeerRegistry, u64, mpsc::UnboundedReceiver<Message>) {
        let rooms = Arc::new(RoomManager::new());
        let presence = Arc::new(PresenceManager::new());
        let reg = PeerRegistry::new(
            presence.clone(),
            rooms.clone(),
            Arc::new(FirehoseMetrics::new()),
        );
        let (tx, rx) = mpsc::unbounded_channel();
        reg.register("app".into(), make_meta("main"), tx).await;
        rooms.subscribe("app".into(), vec!["pi".into()]).await;
        presence.subscribe("app".into(), vec!["pi".into()]).await;
        let mut meta = make_meta("main");
        meta.name = Some("routing-agent".into());
        meta.display = Some(display(0, None));
        let (tx, _) = mpsc::unbounded_channel();
        let conn = reg.register("pi".into(), meta, tx).await;
        let mut rx = rx;
        assert_eq!(recv_frame(&mut rx)["type"], "room_announced");
        assert_eq!(recv_frame(&mut rx)["type"], "peer_online");
        (reg, conn, rx)
    }

    fn recv_frame(rx: &mut mpsc::UnboundedReceiver<Message>) -> serde_json::Value {
        serde_json::from_str(rx.try_recv().unwrap().to_text().unwrap()).unwrap()
    }

    async fn rename(reg: &PeerRegistry, conn: u64, value: crate::rooms::RoomDisplay) -> bool {
        reg.update_room_meta(
            "pi",
            "main",
            conn,
            RoomMetaPatch {
                display: Some(value),
                ..Default::default()
            },
        )
        .await
    }

    #[tokio::test]
    async fn display_rename_reset_preserves_routing_and_legacy_metadata() {
        let (reg, conn, mut rx) = display_fixture().await;
        assert!(rename(&reg, conn, display(1, Some("Pi · system"))).await);
        let v = recv_meta(&mut rx);
        assert_eq!(v["meta"]["display"]["name"], "Pi · system");
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                conn,
                RoomMetaPatch {
                    model: Some(Some("opus".into())),
                    thinking: Some(Some("high".into())),
                    working: Some(true),
                    ..Default::default()
                }
            )
            .await
        );
        let v = recv_meta(&mut rx);
        assert_eq!(v["meta"]["display"]["revision"], 1);
        assert_eq!(v["meta"]["working"], true);
        assert!(rename(&reg, conn, display(2, None)).await);
        let v = recv_meta(&mut rx);
        assert!(v["meta"]["display"].is_object());
        assert!(v["meta"]["display"]["name"].is_null());
        let meta = reg.rooms_of("pi").pop().unwrap();
        assert_eq!(meta.name.as_deref(), Some("routing-agent"));
        assert_eq!(meta.room_id, "main");
        assert_eq!(meta.model.as_deref(), Some("opus"));
        assert_eq!(meta.thinking.as_deref(), Some("high"));
        assert!(meta.working);
        assert_eq!(meta.display, Some(display(2, None)));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_updates_require_exact_connection_room_and_hello_incarnation() {
        let (reg, conn, mut rx) = display_fixture().await;
        assert!(!rename(&reg, EXTERNAL, display(1, Some("wrong conn"))).await);
        assert!(
            !reg.update_room_meta(
                "other",
                "main",
                conn,
                RoomMetaPatch {
                    display: Some(display(1, Some("wrong peer"))),
                    ..Default::default()
                }
            )
            .await
        );
        let (tx, _) = mpsc::unbounded_channel();
        reg.register("pi".into(), make_meta("other"), tx).await;
        assert_eq!(recv_frame(&mut rx)["type"], "room_announced");
        assert!(
            !reg.update_room_meta(
                "pi",
                "other",
                conn,
                RoomMetaPatch {
                    display: Some(display(1, Some("wrong room"))),
                    ..Default::default()
                }
            )
            .await
        );
        for field in ["epoch", "native_session_id"] {
            let mut wrong = display(1, Some("wrong identity"));
            if field == "epoch" {
                wrong.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
            } else {
                wrong.native_session_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
            }
            assert!(!rename(&reg, conn, wrong).await);
        }
        assert!(rename(&reg, conn, display(2, Some("current"))).await);
        recv_meta(&mut rx);
        for value in [
            display(1, Some("old")),
            display(2, Some("current")),
            display(2, Some("conflict")),
        ] {
            assert!(!rename(&reg, conn, value).await);
        }
        assert_eq!(
            reg.rooms_of("pi")
                .into_iter()
                .find(|r| r.room_id == "main")
                .unwrap()
                .display,
            Some(display(2, Some("current")))
        );
        reg.unregister("pi", "main", conn).await;
        assert_eq!(recv_frame(&mut rx)["type"], "room_ended");
        assert!(!rename(&reg, conn, display(3, None)).await);
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_ambiguity_registration_disconnect_and_snapshots_agree() {
        for kind in ["epoch", "native", "legacy"] {
            let (reg, conn, mut rx) = display_fixture().await;
            let mut meta = make_meta("main");
            meta.display = match kind {
                "legacy" => None,
                "conflict" => Some(display(0, Some("conflicting value"))),
                _ => {
                    let mut d = display(0, None);
                    if kind == "epoch" {
                        d.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
                    } else {
                        d.native_session_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
                    }
                    Some(d)
                }
            };
            let (tx, _) = mpsc::unbounded_channel();
            let other = reg.register("pi".into(), meta, tx).await;
            let v = recv_meta(&mut rx);
            assert!(v["meta"].get("display").unwrap().is_null());
            let snapshot = serde_json::to_value(reg.rooms_of("pi")).unwrap();
            assert!(snapshot[0].get("display").is_none());
            assert!(rename(&reg, conn, display(1, Some("not authoritative"))).await);
            let v = recv_meta(&mut rx);
            assert!(v["meta"]["display"].is_null());
            assert!(reg.rooms_of("pi")[0].display.is_none());
            reg.unregister("pi", "main", other).await;
            let v = recv_frame(&mut rx);
            assert_eq!(v["type"], "room_announced");
            assert_eq!(
                v["display"],
                serde_json::to_value(display(1, Some("not authoritative"))).unwrap()
            );
            assert_eq!(
                reg.rooms_of("pi")[0].display,
                Some(display(1, Some("not authoritative")))
            );
            assert!(
                rx.try_recv().is_err(),
                "no false presence or room lifecycle churn"
            );
        }
    }

    #[tokio::test]
    async fn display_same_incarnation_uses_highest_revision_without_cross_connection_copy() {
        let (reg, conn, mut rx) = display_fixture().await;
        let mut meta = make_meta("main");
        meta.display = Some(display(0, None));
        let (tx, _) = mpsc::unbounded_channel();
        let other = reg.register("pi".into(), meta, tx).await;
        assert!(rx.try_recv().is_err());
        assert!(rename(&reg, conn, display(2, Some("new"))).await);
        recv_meta(&mut rx);
        assert!(!rename(&reg, other, display(2, Some("conflict"))).await);
        assert!(rx.try_recv().is_err());
        // Other connection still owns revision 0, not a copied revision 2.
        assert!(
            rename(
                &reg,
                other,
                display(1, Some("older but valid for this conn"))
            )
            .await
        );
        assert_eq!(recv_meta(&mut rx)["meta"]["display"]["name"], "new");
        assert_eq!(reg.rooms_of("pi")[0].display, Some(display(2, Some("new"))));
        reg.unregister("pi", "main", conn).await;
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        assert!(
            reg.rooms_of("pi")[0].display.is_none(),
            "never expose a lower-revision alias on failover"
        );
        assert!(rename(&reg, other, display(2, Some("new"))).await);
        let v = recv_frame(&mut rx);
        assert_eq!(v["type"], "room_announced");
        assert_eq!(v["display"]["revision"], 2);
        assert_eq!(reg.rooms_of("pi")[0].display, Some(display(2, Some("new"))));
        assert!(rename(&reg, other, display(3, None)).await);
        assert!(recv_meta(&mut rx)["meta"]["display"]["name"].is_null());
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_legacy_cannot_bootstrap_and_legacy_duplicates_do_not_churn() {
        let (reg, pi, mut rx) = meta_fixture().await;
        assert!(!rename(&reg, 0, display(1, Some("not advertised"))).await);
        let (tx, _) = mpsc::unbounded_channel();
        let conn = reg.register(pi.clone(), make_meta("main"), tx).await;
        assert!(reg.rooms_of(&pi)[0].display.is_none());
        reg.unregister(&pi, "main", conn).await;
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_same_revision_conflict_is_fenced_after_disconnect_until_newer_data() {
        let (reg, conn, mut rx) = display_fixture().await;
        let mut meta = make_meta("main");
        meta.display = Some(display(0, Some("conflicting")));
        let (tx, _) = mpsc::unbounded_channel();
        let other = reg.register("pi".into(), meta, tx).await;
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        reg.unregister("pi", "main", other).await;
        assert!(reg.rooms_of("pi")[0].display.is_none());
        assert!(
            rx.try_recv().is_err(),
            "conflicting revision must not regain authority by disconnect"
        );
        assert!(rename(&reg, conn, display(1, Some("coherent"))).await);
        let v = recv_frame(&mut rx);
        assert_eq!(v["type"], "room_announced");
        assert_eq!(v["display"]["name"], "coherent");
        // A reconnect at the same accepted revision with a different value fences it again.
        let mut meta = make_meta("main");
        meta.display = Some(display(1, Some("conflicting again")));
        let (tx, _) = mpsc::unbounded_channel();
        let other = reg.register("pi".into(), meta, tx).await;
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        assert!(rename(&reg, other, display(2, Some("new coherent"))).await);
        assert_eq!(recv_frame(&mut rx)["type"], "room_announced");
        assert_eq!(
            reg.rooms_of("pi")[0].display,
            Some(display(2, Some("new coherent")))
        );
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_incarnation_switch_refreshes_same_room_without_presence_churn() {
        let (reg, conn, mut rx) = display_fixture().await;
        let mut meta = make_meta("main");
        let mut next = display(0, Some("new native session"));
        next.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
        meta.display = Some(next.clone());
        let (tx, _) = mpsc::unbounded_channel();
        reg.register("pi".into(), meta, tx).await;
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        reg.unregister("pi", "main", conn).await;
        let frame = recv_frame(&mut rx);
        assert_eq!(frame["type"], "room_announced");
        assert_eq!(frame["room_id"], "main");
        assert_eq!(reg.rooms_of("pi")[0].display, Some(next));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_ledger_overflow_fails_closed_until_last_connection_removal() {
        let (reg, conn, mut rx) = display_fixture().await;
        for incarnation in 1..=MAX_DISPLAY_INCARNATIONS {
            let mut meta = make_meta("main");
            let mut d = display(0, None);
            d.epoch = format!("{:08x}-dddd-4ddd-8ddd-dddddddddddd", incarnation);
            meta.display = Some(d);
            let (tx, _) = mpsc::unbounded_channel();
            let other = reg.register("pi".into(), meta, tx).await;
            reg.unregister("pi", "main", other).await;
            while rx.try_recv().is_ok() {}
        }
        assert!(reg.rooms_of("pi")[0].display.is_none());
        assert!(rename(&reg, conn, display(1, Some("overflow remains closed"))).await);
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        let key = ("pi".into(), "main".into());
        {
            let lock = reg.senders.lock().unwrap();
            assert_eq!(
                lock[&key].display_high_water.len(),
                MAX_DISPLAY_INCARNATIONS
            );
            assert!(lock[&key].display_overflowed);
        }
        reg.unregister("pi", "main", conn).await;
        assert_eq!(recv_frame(&mut rx)["type"], "room_ended");
        assert_eq!(recv_frame(&mut rx)["type"], "peer_offline");
        assert!(!reg.senders.lock().unwrap().contains_key(&key));
        let mut meta = make_meta("main");
        meta.display = Some(display(0, Some("fresh lifecycle")));
        let (tx, _) = mpsc::unbounded_channel();
        reg.register("pi".into(), meta, tx).await;
        assert_eq!(recv_frame(&mut rx)["display"]["name"], "fresh lifecycle");
        assert_eq!(recv_frame(&mut rx)["type"], "peer_online");
        assert_eq!(
            reg.rooms_of("pi")[0].display,
            Some(display(0, Some("fresh lifecycle")))
        );
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn display_room_frames_linearize_with_mutation_after_subscription_prefetch() {
        let (reg, conn, mut rx) = display_fixture().await;
        let lookup_gate = reg.rooms.pause_subscriber_lookup().await;
        let mut old_update = Box::pin(rename(&reg, conn, display(1, Some("older verified"))));
        assert!(futures_util::poll!(old_update.as_mut()).is_pending());
        let mut next = display(0, Some("new incarnation"));
        next.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
        let mut meta = make_meta("main");
        meta.display = Some(next.clone());
        let (tx, _) = mpsc::unbounded_channel();
        let mut competing_register = Box::pin(reg.register("pi".into(), meta, tx));
        assert!(futures_util::poll!(competing_register.as_mut()).is_pending());
        // At the only await boundary, neither operation has computed/mutated
        // a snapshot that could later queue behind a newer invalidation.
        assert_eq!(reg.rooms_of("pi")[0].display, Some(display(0, None)));
        assert!(rx.try_recv().is_err());
        drop(lookup_gate);
        assert!(old_update.await);
        competing_register.await;
        assert_eq!(
            recv_meta(&mut rx)["meta"]["display"]["name"],
            "older verified"
        );
        assert!(recv_meta(&mut rx)["meta"]["display"].is_null());
        assert!(reg.rooms_of("pi")[0].display.is_none());
        reg.unregister("pi", "main", conn).await;
        let frame = recv_frame(&mut rx);
        assert_eq!(frame["type"], "room_announced");
        assert_eq!(
            frame["display"],
            serde_json::to_value(next.clone()).unwrap()
        );
        assert_eq!(reg.rooms_of("pi")[0].display, Some(next));
        assert!(
            rx.try_recv().is_err(),
            "no old verified frame after invalidation/incarnation refresh"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn display_unsubscribe_and_disconnect_cleanup_wait_for_mutation_enqueue() {
        for cleanup_all in [false, true] {
            let (reg, conn, mut rx) = display_fixture().await;
            let reg = Arc::new(reg);
            let (arrived, resume) = reg.rooms.pause_after_subscriber_prefetch();
            let changing = {
                let reg = reg.clone();
                tokio::spawn(async move {
                    rename(&reg, conn, display(1, Some("queued before unsubscribe"))).await
                })
            };
            tokio::time::timeout(std::time::Duration::from_secs(2), arrived)
                .await
                .unwrap()
                .unwrap();
            let mut unsubscribe = Box::pin(async {
                if cleanup_all {
                    reg.rooms.unsubscribe_all("app").await;
                } else {
                    reg.rooms.unsubscribe("app", vec!["pi".into()]).await;
                }
            });
            let pending = futures_util::poll!(unsubscribe.as_mut()).is_pending();
            resume.send(()).unwrap();
            assert!(
                tokio::time::timeout(std::time::Duration::from_secs(2), changing)
                    .await
                    .unwrap()
                    .unwrap()
            );
            if pending {
                unsubscribe.await;
            }
            assert!(
                pending,
                "subscription membership remains locked through enqueue"
            );
            assert_eq!(
                recv_meta(&mut rx)["meta"]["display"]["name"],
                "queued before unsubscribe"
            );
            assert!(!reg.rooms.subscribers_of("pi").await.contains(&"app".into()));
            // The handler's disconnect order is unregister then unsubscribe_all;
            // neither holds senders while awaiting subscription cleanup.
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                reg.unregister("pi", "main", conn).await;
                reg.rooms.unsubscribe_all("pi").await;
            })
            .await
            .unwrap();
            assert_eq!(recv_frame(&mut rx)["type"], "peer_offline");
            assert!(rx.try_recv().is_err());
        }
    }

    #[tokio::test]
    async fn display_invalid_combined_patch_is_atomic_and_legacy_nullable_patches_still_clear() {
        let (reg, conn, mut rx) = display_fixture().await;
        let mut wrong = display(1, Some("wrong epoch"));
        wrong.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
        assert!(
            !reg.update_room_meta(
                "pi",
                "main",
                conn,
                RoomMetaPatch {
                    display: Some(wrong),
                    model: Some(Some("not applied".into())),
                    thinking: Some(Some("not applied".into())),
                    working: Some(true),
                }
            )
            .await
        );
        let meta = &reg.rooms_of("pi")[0];
        assert!(!meta.working);
        assert!(meta.model.is_none());
        assert!(meta.thinking.is_none());
        assert_eq!(meta.display, Some(display(0, None)));
        assert!(rx.try_recv().is_err());
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                conn,
                RoomMetaPatch {
                    display: Some(display(1, Some("valid"))),
                    model: Some(Some("opus".into())),
                    thinking: Some(Some("high".into())),
                    working: Some(true),
                }
            )
            .await
        );
        recv_meta(&mut rx);
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                conn,
                RoomMetaPatch {
                    model: Some(None),
                    thinking: Some(None),
                    working: Some(false),
                    ..Default::default()
                }
            )
            .await
        );
        let v = recv_meta(&mut rx);
        assert!(v["meta"].get("model").is_none());
        assert!(v["meta"].get("thinking").is_none());
        assert_eq!(v["meta"]["working"], false);
        assert_eq!(v["meta"]["display"]["name"], "valid");
        let snapshot = &reg.rooms_of("pi")[0];
        assert!(snapshot.model.is_none());
        assert!(snapshot.thinking.is_none());
        assert!(!snapshot.working);
        assert_eq!(snapshot.display, Some(display(1, Some("valid"))));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn display_subscribe_and_check_cannot_miss_invalidation_after_prefetch() {
        for mutation in ["register", "update", "unregister"] {
            let (reg, conn, mut old_rx) = display_fixture().await;
            assert!(rename(&reg, conn, display(1, Some("old verified"))).await);
            recv_meta(&mut old_rx);
            if mutation == "unregister" {
                let mut stale = make_meta("main");
                stale.display = Some(display(0, None));
                let (tx, _) = mpsc::unbounded_channel();
                reg.register("pi".into(), stale, tx).await;
                assert!(old_rx.try_recv().is_err());
            }
            let reg = Arc::new(reg);
            let (tx, mut late_rx) = mpsc::unbounded_channel();
            let late_conn = reg.register("late_app".into(), make_meta("main"), tx).await;
            let (arrived, resume) = reg.rooms.pause_after_subscriber_prefetch();
            let changing = {
                let reg = reg.clone();
                tokio::spawn(async move {
                    match mutation {
                        "register" => {
                            let mut meta = make_meta("main");
                            let mut next = display(0, Some("competing"));
                            next.epoch = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into();
                            meta.display = Some(next);
                            let (tx, _) = mpsc::unbounded_channel();
                            reg.register("pi".into(), meta, tx).await;
                        }
                        "update" => {
                            assert!(rename(&reg, conn, display(2, Some("new verified"))).await);
                        }
                        "unregister" => {
                            reg.unregister("pi", "main", conn).await;
                        }
                        _ => unreachable!(),
                    }
                })
            };
            tokio::time::timeout(std::time::Duration::from_secs(2), arrived)
                .await
                .unwrap()
                .unwrap();
            // Pause AFTER lookup but BEFORE mutation. The real handler order
            // subscribe -> queued rooms_check cannot pass subscription sync.
            let mut subscribe_and_check = Box::pin(async {
                reg.rooms
                    .subscribe("late_app".into(), vec!["pi".into()])
                    .await;
                reg.queue_rooms_check(
                    "late_app",
                    "main",
                    late_conn,
                    &["pi".into()],
                    &mut HashMap::new(),
                )
            });
            let early = match futures_util::poll!(subscribe_and_check.as_mut()) {
                std::task::Poll::Ready(queued) => Some(queued),
                std::task::Poll::Pending => None,
            };
            resume.send(()).unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(2), changing)
                .await
                .unwrap()
                .unwrap();
            let checked = match early {
                Some(queued) => queued,
                None => subscribe_and_check.await,
            };
            assert!(checked);
            assert!(
                early.is_none(),
                "{mutation}: subscribe must wait through mutation/enqueue"
            );
            let current = serde_json::to_value(reg.rooms_of("pi")).unwrap()[0]["display"].clone();
            let mut delivered_snapshot = None;
            let mut received_current_push = false;
            while let Ok(message) = late_rx.try_recv() {
                let frame: serde_json::Value =
                    serde_json::from_str(message.to_text().unwrap()).unwrap();
                if frame["type"] == "rooms" {
                    delivered_snapshot = Some(frame["rooms"][0]["display"].clone());
                }
                if frame["type"] == "room_meta_updated" {
                    received_current_push |= frame["meta"]["display"] == current;
                }
            }
            assert!(
                delivered_snapshot.unwrap() == current || received_current_push,
                "{mutation}: subscribe/check must not retain old authority and miss the only change"
            );
        }
    }

    #[tokio::test]
    async fn rooms_check_queue_is_exact_connection_and_preserves_dedup_and_legacy_snapshots() {
        let reg = make_registry();
        let (tx1, mut rx1) = mpsc::unbounded_channel();
        let conn1 = reg.register("app".into(), make_meta("main"), tx1).await;
        let (tx2, mut rx2) = mpsc::unbounded_channel();
        let conn2 = reg.register("app".into(), make_meta("main"), tx2).await;
        let (tx3, mut rx3) = mpsc::unbounded_channel();
        reg.register("app".into(), make_meta("other"), tx3).await;
        let (tx, _) = mpsc::unbounded_channel();
        let pi_conn = reg.register("pi".into(), make_meta("main"), tx).await;
        let mut cache1 = HashMap::new();
        assert!(reg.queue_rooms_check(
            "app",
            "main",
            conn1,
            &["pi".into(), "offline".into(), "pi".into()],
            &mut cache1
        ));
        let pi = recv_frame(&mut rx1);
        assert_eq!(pi["type"], "rooms");
        assert_eq!(pi["peer"], "pi");
        assert_eq!(pi["rooms"][0]["working"], false);
        assert!(pi["rooms"][0].get("display").is_none());
        assert_eq!(recv_frame(&mut rx1)["rooms"], serde_json::json!([]));
        assert!(rx1.try_recv().is_err());
        assert!(rx2.try_recv().is_err());
        assert!(rx3.try_recv().is_err());
        assert_eq!(&reg.metrics.snapshot()[4..], &[2, 1]);
        assert!(reg.queue_rooms_check("app", "main", conn1, &["pi".into()], &mut cache1));
        assert!(rx1.try_recv().is_err());
        let mut cache2 = HashMap::new();
        assert!(reg.queue_rooms_check("app", "main", conn2, &["pi".into()], &mut cache2));
        assert_eq!(recv_frame(&mut rx2), pi);
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                pi_conn,
                RoomMetaPatch {
                    model: Some(Some("opus".into())),
                    working: Some(true),
                    ..Default::default()
                }
            )
            .await
        );
        assert!(reg.queue_rooms_check("app", "main", conn1, &["pi".into()], &mut cache1));
        let changed = recv_frame(&mut rx1);
        assert_eq!(changed["rooms"][0]["model"], "opus");
        assert_eq!(changed["rooms"][0]["working"], true);
        assert_eq!(&reg.metrics.snapshot()[4..], &[4, 2]);
        for (peer, room, conn) in [
            ("app", "main", EXTERNAL),
            ("app", "other", conn1),
            ("unknown", "main", conn1),
        ] {
            assert!(!reg.queue_rooms_check(peer, room, conn, &["pi".into()], &mut cache1));
        }
        reg.unregister("app", "main", conn1).await;
        assert!(!reg.queue_rooms_check("app", "main", conn1, &["pi".into()], &mut cache1));
        assert!(rx1.try_recv().is_err());
        assert!(rx2.try_recv().is_err());
        assert!(rx3.try_recv().is_err());
    }

    #[tokio::test]
    async fn rooms_check_closed_request_queue_does_not_advance_cache_or_emit_metric() {
        let reg = make_registry();
        let (tx, rx) = mpsc::unbounded_channel();
        let conn = reg.register("app".into(), make_meta("main"), tx).await;
        drop(rx);
        let mut cache = HashMap::new();
        assert!(!reg.queue_rooms_check("app", "main", conn, &["pi".into()], &mut cache));
        assert!(cache.is_empty());
        assert_eq!(&reg.metrics.snapshot()[4..], &[0, 0]);
    }
}
