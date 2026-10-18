//! Loopback-only real router for the Flutter/extension launch acceptance test.
use std::{net::SocketAddr, sync::Arc};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let db = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("temporary database path required"))?;
    let presence = Arc::new(relay::PresenceManager::new());
    let rooms = Arc::new(relay::RoomManager::new());
    let metrics = Arc::new(relay::FirehoseMetrics::new());
    let state = relay::AppState {
        registry: Arc::new(relay::PeerRegistry::new(
            presence.clone(),
            rooms.clone(),
            metrics.clone(),
        )),
        presence,
        rooms,
        metrics,
        mesh: Arc::new(relay::MeshStore::open(&db)?),
        mesh_auth: Arc::new(relay::MeshAuthCache::new()),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    println!("{}", listener.local_addr()?.port());
    axum::serve(
        listener,
        relay::build_router(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}
