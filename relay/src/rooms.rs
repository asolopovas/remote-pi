use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tokio::sync::Mutex;

/// Display-only authority advertised by an authenticated connection's hello.
/// This identity does not authorize routing, membership or native history.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct RoomDisplay {
    pub native_session_id: String,
    pub epoch: String,
    pub revision: u64,
    pub name: Option<String>,
}

impl RoomDisplay {
    pub const MAX_REVISION: u64 = 9_007_199_254_740_991;

    /// Accept only a bounded whole object; null outside the object is reserved
    /// for Relay-to-subscriber authority invalidation, not producer updates.
    pub fn from_value(value: &serde_json::Value) -> Option<Self> {
        let obj = value.as_object()?;
        if obj.len() != 4 {
            return None;
        }
        let native_session_id = obj.get("native_session_id")?.as_str()?;
        let epoch = obj.get("epoch")?.as_str()?;
        if !is_uuid(native_session_id) || !is_uuid(epoch) {
            return None;
        }
        let revision = obj.get("revision")?.as_u64()?;
        if revision > Self::MAX_REVISION {
            return None;
        }
        let name = match obj.get("name")? {
            serde_json::Value::Null => None,
            serde_json::Value::String(name)
                if name.len() <= 512
                    && name.chars().count() <= 128
                    && !name.chars().any(is_display_control) =>
            {
                Some(name.clone())
            }
            _ => return None,
        };
        Some(Self {
            native_session_id: native_session_id.into(),
            epoch: epoch.into(),
            revision,
            name,
        })
    }

    pub fn same_incarnation(&self, other: &Self) -> bool {
        self.native_session_id == other.native_session_id && self.epoch == other.epoch
    }
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

fn is_display_control(c: char) -> bool {
    // Unicode Cc/Cf plus line/paragraph separators, matching producer cleanup.
    c.is_control()
        || matches!(c as u32,
        0x00ad | 0x0600..=0x0605 | 0x061c | 0x06dd | 0x070f | 0x0890..=0x0891 |
        0x08e2 | 0x180e | 0x200b..=0x200f | 0x2028..=0x202e | 0x2060..=0x2064 |
        0x2066..=0x206f | 0xfeff | 0xfff9..=0xfffb | 0x110bd | 0x110cd |
        0x13430..=0x1343f | 0x1bca0..=0x1bca3 | 0x1d173..=0x1d17a |
        0xe0001 | 0xe0020..=0xe007f)
}

/// Metadata about one active Pi room (sub-channel of a peer_id).
#[derive(Debug, Clone, serde::Serialize)]
pub struct RoomMeta {
    pub room_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Active Claude model for this room (plano 18). None = not reported yet.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Active thinking level for this room (plano 28). Opaque string from the
    /// Pi's perspective (e.g. `"high"`, `"medium"`, `"none"`) — the relay
    /// never interprets it. None = not reported yet.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
    /// Whether this room currently has an in-flight agent turn (plano 32).
    /// A plain bool with the same merge-patch semantics as `thinking`: a
    /// `room_meta_update` that omits `working` leaves it unchanged — it never
    /// auto-clears. Defaults to `false` until the Pi reports otherwise, and is
    /// always serialized so subscribers can rely on its presence.
    pub working: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display: Option<RoomDisplay>,
    pub started_at: i64,
}

/// Patch over the mutable `RoomMeta` fields. Each entry distinguishes
/// "field absent in the update" (outer `None`, meaning "leave current") from
/// "field present in the update" (outer `Some(_)`, whose inner `None` means
/// "clear to null" and whose inner `Some(s)` means "set to s").
///
/// Built by the `room_meta_update` handler from the `meta` JSON object; the
/// relay validates display authority; model/thinking strings remain opaque.
#[derive(Debug, Default, Clone)]
pub struct RoomMetaPatch {
    pub model: Option<Option<String>>,
    pub thinking: Option<Option<String>>,
    /// `working` is a non-nullable bool, so the patch is a single `Option`:
    /// `None` = field absent (leave current), `Some(b)` = set to `b`. There is
    /// no "clear to null" — `false` *is* the cleared state.
    pub working: Option<bool>,
    /// Whole validated object; omission preserves connection-local authority.
    pub display: Option<RoomDisplay>,
}

impl RoomMetaPatch {
    /// `true` when at least one field is present (i.e. the patch is a no-op
    /// otherwise). Used by the registry to skip work when callers send empty
    /// `meta: {}`.
    pub fn is_empty(&self) -> bool {
        self.model.is_none()
            && self.thinking.is_none()
            && self.working.is_none()
            && self.display.is_none()
    }
}

#[derive(Debug, Default)]
struct Inner {
    /// subscribers_of[X] = set of peer_ids that want push when X opens/closes a room.
    subscribers_of: HashMap<String, HashSet<String>>,
    /// subscriptions_by[Y] = set of peer_ids that Y is watching (for efficient cleanup).
    subscriptions_by: HashMap<String, HashSet<String>>,
}

/// Tracks who has subscribed to room announcements for which peer_ids.
/// Complements PresenceManager: same subscription graph, separate broadcast semantics.
#[derive(Clone, Debug, Default)]
pub struct RoomManager {
    inner: Arc<Mutex<Inner>>,
    #[cfg(test)]
    prefetch_pause: Arc<std::sync::Mutex<Option<SubscriberPrefetchPause>>>,
}

#[cfg(test)]
#[derive(Debug)]
struct SubscriberPrefetchPause {
    arrived: tokio::sync::oneshot::Sender<()>,
    resume: std::sync::mpsc::Receiver<()>,
}

impl RoomManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replaces `subscriber`'s full subscription list with `peers`.
    /// Empty list = unsubscribe all.
    pub async fn subscribe(&self, subscriber: String, peers: Vec<String>) {
        let mut g = self.inner.lock().await;
        if let Some(old) = g.subscriptions_by.remove(&subscriber) {
            for peer in &old {
                if let Some(set) = g.subscribers_of.get_mut(peer) {
                    set.remove(&subscriber);
                }
            }
        }
        let new_set: HashSet<String> = peers.into_iter().collect();
        for peer in &new_set {
            g.subscribers_of
                .entry(peer.clone())
                .or_default()
                .insert(subscriber.clone());
        }
        if !new_set.is_empty() {
            g.subscriptions_by.insert(subscriber, new_set);
        }
    }

    /// Removes `peers` from `subscriber`'s watched list.
    pub async fn unsubscribe(&self, subscriber: &str, peers: Vec<String>) {
        let mut g = self.inner.lock().await;
        for peer in &peers {
            if let Some(set) = g.subscribers_of.get_mut(peer) {
                set.remove(subscriber);
            }
            if let Some(subs) = g.subscriptions_by.get_mut(subscriber) {
                subs.remove(peer);
            }
        }
    }

    /// Removes all subscriptions for `subscriber` (called on disconnect to prevent leaks).
    pub async fn unsubscribe_all(&self, subscriber: &str) {
        let mut g = self.inner.lock().await;
        if let Some(peers) = g.subscriptions_by.remove(subscriber) {
            for peer in &peers {
                if let Some(set) = g.subscribers_of.get_mut(peer) {
                    set.remove(subscriber);
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) async fn pause_subscriber_lookup(&self) -> impl Send {
        self.inner.clone().lock_owned().await
    }

    #[cfg(test)]
    pub(crate) fn pause_after_subscriber_prefetch(
        &self,
    ) -> (
        tokio::sync::oneshot::Receiver<()>,
        std::sync::mpsc::Sender<()>,
    ) {
        let (arrived, arrived_rx) = tokio::sync::oneshot::channel();
        let (resume_tx, resume) = std::sync::mpsc::channel();
        *self.prefetch_pause.lock().unwrap() = Some(SubscriberPrefetchPause { arrived, resume });
        (arrived_rx, resume_tx)
    }

    // Bounded test-only worker gate, after lookup and before any senders lock.
    #[cfg(test)]
    fn wait_after_subscriber_prefetch(&self) {
        let pause = self.prefetch_pause.lock().unwrap().take();
        if let Some(pause) = pause {
            let _ = pause.arrived.send(());
            pause
                .resume
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
        }
    }

    /// Runs a synchronous room mutation/enqueue while subscription membership
    /// is held stable. Lock order is RoomManager -> registry senders; callbacks
    /// must not await or acquire RoomManager again.
    pub(crate) async fn with_subscribers<R>(
        &self,
        peer: &str,
        apply: impl FnOnce(Vec<String>) -> R,
    ) -> R {
        let g = self.inner.lock().await;
        let subscribers = g
            .subscribers_of
            .get(peer)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default();
        #[cfg(test)]
        self.wait_after_subscriber_prefetch();
        let result = apply(subscribers);
        drop(g); // membership stays locked through mutation and enqueue
        result
    }

    /// Returns everyone who subscribed to room events for `peer`.
    pub async fn subscribers_of(&self, peer: &str) -> Vec<String> {
        self.with_subscribers(peer, |subscribers| subscribers).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_display_value() -> serde_json::Value {
        serde_json::json!({
            "native_session_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "epoch": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "revision": 0, "name": null,
        })
    }

    #[test]
    fn display_validation_bounds_shape_uuid_revision_and_plain_unicode_name() {
        let value = valid_display_value();
        assert!(RoomDisplay::from_value(&value).is_some());
        for field in ["native_session_id", "epoch", "revision", "name"] {
            let mut missing = value.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(
                RoomDisplay::from_value(&missing).is_none(),
                "missing {field}"
            );
        }
        let mut extra = value.clone();
        extra["unexpected"] = true.into();
        assert!(RoomDisplay::from_value(&extra).is_none());
        for uuid in [
            "",
            "native-name",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaz",
            "aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa",
            "a".repeat(4096).as_str(),
        ] {
            for field in ["native_session_id", "epoch"] {
                let mut invalid = value.clone();
                invalid[field] = uuid.into();
                assert!(RoomDisplay::from_value(&invalid).is_none());
            }
        }
        for revision in [
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!(1.0),
            serde_json::json!("1"),
            serde_json::json!(null),
            serde_json::json!(RoomDisplay::MAX_REVISION + 1),
        ] {
            let mut invalid = value.clone();
            invalid["revision"] = revision;
            assert!(RoomDisplay::from_value(&invalid).is_none());
        }
        let mut max = value.clone();
        max["revision"] = RoomDisplay::MAX_REVISION.into();
        max["name"] = "🎛".repeat(128).into();
        assert!(RoomDisplay::from_value(&max).is_some());
        for name in [
            serde_json::json!("🎛".repeat(129)),
            serde_json::json!(true),
            serde_json::json!([]),
            serde_json::json!("escape\u{1b}"),
            serde_json::json!("line\n"),
            serde_json::json!("bidi\u{202e}"),
            serde_json::json!("format\u{200b}"),
            serde_json::json!("separator\u{2028}"),
            serde_json::json!("tag\u{e0020}"),
        ] {
            let mut invalid = value.clone();
            invalid["name"] = name;
            assert!(RoomDisplay::from_value(&invalid).is_none());
        }
        let parsed = RoomDisplay::from_value(&value).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), value);
    }

    #[tokio::test]
    async fn subscribe_replaces_list() {
        let rm = RoomManager::new();
        rm.subscribe("B".into(), vec!["A".into(), "C".into()]).await;
        assert!(rm.subscribers_of("A").await.contains(&"B".to_string()));

        rm.subscribe("B".into(), vec!["A".into()]).await;
        assert!(!rm.subscribers_of("C").await.contains(&"B".to_string()));
    }

    #[tokio::test]
    async fn subscribe_empty_equals_unsubscribe_all() {
        let rm = RoomManager::new();
        rm.subscribe("B".into(), vec!["A".into()]).await;
        rm.subscribe("B".into(), vec![]).await;
        assert!(rm.subscribers_of("A").await.is_empty());
    }

    #[tokio::test]
    async fn unsubscribe_all_cleans_subscriber_from_sets() {
        let rm = RoomManager::new();
        rm.subscribe("B".into(), vec!["A".into(), "C".into()]).await;
        rm.unsubscribe_all("B").await;
        assert!(rm.subscribers_of("A").await.is_empty());
        assert!(rm.subscribers_of("C").await.is_empty());
    }
}
