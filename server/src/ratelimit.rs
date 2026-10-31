use std::{
    convert::Infallible,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::request::Parts,
};
use dashmap::DashMap;

/// 固定窗口限速：每个 IP 在一个窗口内最多 max 次。
/// 单进程部署时这就够了；以后多实例再换成 Redis。
pub struct RateLimiter {
    hits: DashMap<IpAddr, (Instant, u32)>,
    max: u32,
    window: Duration,
}

impl RateLimiter {
    pub fn new(max: u32, window: Duration) -> Self {
        Self {
            hits: DashMap::new(),
            max,
            window,
        }
    }

    /// 记一次，返回这次是否还在额度内
    pub fn check(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let mut entry = self.hits.entry(ip).or_insert((now, 0));
        let (start, count) = &mut *entry;
        if now.duration_since(*start) >= self.window {
            *start = now;
            *count = 0;
        }
        *count += 1;
        *count <= self.max
    }

    /// 清掉已经过期的记录，免得内存一直涨
    pub fn purge(&self) {
        let now = Instant::now();
        self.hits
            .retain(|_, (start, _)| now.duration_since(*start) < self.window);
    }
}

/// 请求方的 IP。直连时用 TCP 对端地址；对端是本机（前面有 Caddy）时，
/// 用 X-Forwarded-For 里最后一个地址，也就是 Caddy 看到的真实客户端。
/// 服务端直接暴露在公网时对端不是本机，伪造的 X-Forwarded-For 不会被采信。
pub struct ClientIp(pub IpAddr);

impl<S: Send + Sync> FromRequestParts<S> for ClientIp {
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip())
            .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
        if peer.is_loopback() {
            let forwarded = parts
                .headers
                .get("x-forwarded-for")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.rsplit(',').next())
                .and_then(|ip| ip.trim().parse().ok());
            if let Some(ip) = forwarded {
                return Ok(ClientIp(ip));
            }
        }
        Ok(ClientIp(peer))
    }
}
