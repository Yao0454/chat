mod api;
mod auth;
mod db;
mod error;
mod hub;
mod ratelimit;
mod ws;

use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    routing::{get, post},
    Router,
};
use sqlx::SqlitePool;
use tracing_subscriber::EnvFilter;

use crate::{hub::Hub, ratelimit::RateLimiter};

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub hub: Arc<Hub>,
    /// 登录和注册共用：每个 IP 每分钟最多 10 次
    pub auth_limiter: Arc<RateLimiter>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("chat_server=info")),
        )
        .init();

    let database_url =
        std::env::var("DATABASE_URL").unwrap_or_else(|_| "sqlite://chat.db".to_string());
    let db = db::connect(&database_url).await?;

    // 命令行：chat-server [serve | invite [数量]]
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("invite") => {
            let count: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);
            for _ in 0..count {
                println!("{}", db::create_invite(&db).await?);
            }
            return Ok(());
        }
        Some("serve") | None => {}
        Some(other) => {
            eprintln!("未知命令: {other}\n用法: chat-server [serve | invite [数量]]");
            std::process::exit(2);
        }
    }

    let state = AppState {
        db,
        hub: Arc::new(Hub::default()),
        auth_limiter: Arc::new(RateLimiter::new(10, Duration::from_secs(60))),
    };

    let limiter = state.auth_limiter.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(300));
        loop {
            tick.tick().await;
            limiter.purge();
        }
    });

    let app = Router::new()
        .route("/api/register", post(api::register))
        .route("/api/login", post(api::login))
        .route("/api/logout", post(api::logout))
        .route("/api/me", get(api::me))
        .route("/api/users", get(api::list_users))
        .route("/api/conversations", get(api::list_conversations))
        .route("/api/conversations/direct", post(api::open_direct))
        .route("/ws", get(ws::ws_handler))
        .with_state(state);

    // 部署时放在 Caddy 后面，所以默认只监听本机
    let addr: SocketAddr = std::env::var("BIND")
        .unwrap_or_else(|_| "127.0.0.1:8080".to_string())
        .parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("listening on {addr}");
    // 带上对端地址，限速要用
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;
    Ok(())
}
