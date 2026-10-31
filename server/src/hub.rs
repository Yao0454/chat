use std::sync::atomic::{AtomicU64, Ordering};

use dashmap::DashMap;
use tokio::sync::mpsc::UnboundedSender;

/// 记录每个在线用户的所有连接（一个人可能同时开着多台设备）。
/// 单进程部署时这就够了；以后多实例再换成 Redis pub/sub。
#[derive(Default)]
pub struct Hub {
    conns: DashMap<i64, Vec<(u64, UnboundedSender<String>)>>,
    next_id: AtomicU64,
}

impl Hub {
    pub fn register(&self, user_id: i64, tx: UnboundedSender<String>) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.conns.entry(user_id).or_default().push((id, tx));
        id
    }

    pub fn unregister(&self, user_id: i64, conn_id: u64) {
        if let Some(mut list) = self.conns.get_mut(&user_id) {
            list.retain(|(id, _)| *id != conn_id);
        }
        // 上面的 guard 已经释放，这里再删，避免 DashMap 死锁
        self.conns.remove_if(&user_id, |_, list| list.is_empty());
    }

    pub fn send_to_user(&self, user_id: i64, text: &str) {
        if let Some(list) = self.conns.get(&user_id) {
            for (_, tx) in list.iter() {
                let _ = tx.send(text.to_string());
            }
        }
    }
}
