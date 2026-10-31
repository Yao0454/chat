use std::{collections::HashMap, sync::Mutex, time::Duration};

use axum::{body::Bytes, extract::ws::Message};
use serde::Serialize;

use crate::{
    db::{self, User},
    hub::Hub,
    AppState,
};

/// 响铃多久没人接就自动结束
const RING_TIMEOUT: Duration = Duration::from_secs(45);
/// 一帧 20ms 的 Opus 语音通常不到 200 字节，超过这个大小的直接丢掉
const MAX_AUDIO_FRAME: usize = 2048;

// ---------- 协议 ----------
// 客户端 → 服务端（文本帧）
//   {"type":"call_invite","call_id":"<uuid>","conversation_id":1}   只能在一对一会话里发起
//   {"type":"call_accept","call_id":"..."}
//   {"type":"call_hangup","call_id":"..."}    接听前由被叫发出 = 拒绝；其他情况 = 挂断/取消
// 服务端 → 客户端（文本帧）
//   {"type":"call_incoming","call_id":"...","conversation_id":1,"from":{...}}   发给被叫的所有设备
//   {"type":"call_accepted","call_id":"..."}   发给主叫和接听的那台设备，双方开始收发语音
//   {"type":"call_ended","call_id":"...","reason":"hangup|rejected|busy|offline|timeout|disconnected|answered_elsewhere"}
// 语音（二进制帧）：一帧就是一个 Opus 包，服务端原样转发给通话的另一方

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CallEvent {
    CallIncoming {
        call_id: String,
        conversation_id: i64,
        from: User,
    },
    CallAccepted {
        call_id: String,
    },
    CallEnded {
        call_id: String,
        reason: EndReason,
    },
}

#[derive(Serialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum EndReason {
    Hangup,
    Rejected,
    Busy,
    Offline,
    Timeout,
    Disconnected,
    AnsweredElsewhere,
}

fn text(event: &CallEvent) -> Message {
    Message::Text(serde_json::to_string(event).unwrap_or_default().into())
}

fn ended(call_id: &str, reason: EndReason) -> CallEvent {
    CallEvent::CallEnded {
        call_id: call_id.to_string(),
        reason,
    }
}

struct Call {
    caller_id: i64,
    caller_conn: u64,
    callee_id: i64,
    /// 接听之前为 None：响铃会发到被叫的所有设备，哪台接听就绑定哪台
    callee_conn: Option<u64>,
}

impl Call {
    /// 通知双方通话结束。还在响铃时被叫的每台设备都要收到，好让它们停止响铃
    fn notify_ended(&self, hub: &Hub, call_id: &str, reason: EndReason) {
        let msg = text(&ended(call_id, reason));
        hub.send_to_conn(self.caller_id, self.caller_conn, msg.clone());
        match self.callee_conn {
            Some(conn) => hub.send_to_conn(self.callee_id, conn, msg),
            None => hub.send_to_user(self.callee_id, msg),
        }
    }
}

/// 所有正在进行的通话。单进程部署时放内存里就够了
#[derive(Default)]
pub struct Calls {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    calls: HashMap<String, Call>,
    /// 每个人同一时间只能在一个通话里
    by_user: HashMap<i64, String>,
}

impl Inner {
    fn remove(&mut self, call_id: &str) -> Option<Call> {
        let call = self.calls.remove(call_id)?;
        self.by_user.remove(&call.caller_id);
        self.by_user.remove(&call.callee_id);
        Some(call)
    }
}

/// 发起通话。返回 Err(提示文字) 表示请求本身无效
pub async fn invite(
    state: &AppState,
    user: &User,
    conn: u64,
    call_id: String,
    conversation_id: i64,
) -> Result<(), String> {
    if call_id.is_empty() || call_id.len() > 64 {
        return Err("call_id 无效".into());
    }
    let callee_id = match db::direct_peer(&state.db, conversation_id, user.id).await {
        Ok(Some(id)) => id,
        Ok(None) => return Err("只能在一对一会话里发起语音通话".into()),
        Err(e) => {
            tracing::error!("direct_peer failed: {e}");
            return Err("服务器内部错误".into());
        }
    };

    {
        let mut inner = state.calls.inner.lock().unwrap();
        if inner.by_user.contains_key(&user.id) {
            return Err("你已经在通话中了".into());
        }
        if inner.calls.contains_key(&call_id) {
            return Err("call_id 重复".into());
        }
        let reject = |reason| state.hub.send_to_conn(user.id, conn, text(&ended(&call_id, reason)));
        if inner.by_user.contains_key(&callee_id) {
            reject(EndReason::Busy);
            return Ok(());
        }
        if !state.hub.is_online(callee_id) {
            reject(EndReason::Offline);
            return Ok(());
        }
        inner.calls.insert(
            call_id.clone(),
            Call {
                caller_id: user.id,
                caller_conn: conn,
                callee_id,
                callee_conn: None,
            },
        );
        inner.by_user.insert(user.id, call_id.clone());
        inner.by_user.insert(callee_id, call_id.clone());
    }

    state.hub.send_to_user(
        callee_id,
        text(&CallEvent::CallIncoming {
            call_id: call_id.clone(),
            conversation_id,
            from: user.clone(),
        }),
    );
    tracing::info!(call_id, caller = user.id, callee = callee_id, "call ringing");

    let state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(RING_TIMEOUT).await;
        let mut inner = state.calls.inner.lock().unwrap();
        let still_ringing = inner
            .calls
            .get(&call_id)
            .is_some_and(|c| c.callee_conn.is_none());
        if still_ringing {
            if let Some(call) = inner.remove(&call_id) {
                call.notify_ended(&state.hub, &call_id, EndReason::Timeout);
            }
        }
    });
    Ok(())
}

pub fn accept(state: &AppState, user: &User, conn: u64, call_id: &str) {
    let mut inner = state.calls.inner.lock().unwrap();
    let call = match inner.calls.get_mut(call_id) {
        Some(c) if c.callee_id == user.id && c.callee_conn.is_none() => c,
        // 已经结束（比如刚好超时或者对方取消了），让这台设备也结束
        _ => {
            state
                .hub
                .send_to_conn(user.id, conn, text(&ended(call_id, EndReason::Hangup)));
            return;
        }
    };
    call.callee_conn = Some(conn);

    let accepted = text(&CallEvent::CallAccepted {
        call_id: call_id.to_string(),
    });
    state
        .hub
        .send_to_conn(call.caller_id, call.caller_conn, accepted.clone());
    state.hub.send_to_conn(user.id, conn, accepted);
    state.hub.send_to_user_except(
        user.id,
        conn,
        text(&ended(call_id, EndReason::AnsweredElsewhere)),
    );
    tracing::info!(call_id, "call accepted");
}

pub fn hangup(state: &AppState, user: &User, conn: u64, call_id: &str) {
    let mut inner = state.calls.inner.lock().unwrap();
    let reason = match inner.calls.get(call_id) {
        Some(c) if c.caller_id == user.id && c.caller_conn == conn => EndReason::Hangup,
        Some(c) if c.callee_id == user.id && c.callee_conn.is_none() => EndReason::Rejected,
        Some(c) if c.callee_id == user.id && c.callee_conn == Some(conn) => EndReason::Hangup,
        _ => {
            state
                .hub
                .send_to_conn(user.id, conn, text(&ended(call_id, EndReason::Hangup)));
            return;
        }
    };
    if let Some(call) = inner.remove(call_id) {
        call.notify_ended(&state.hub, call_id, reason);
    }
    tracing::info!(call_id, "call ended");
}

/// 连接断开时，结束绑定在这条连接上的通话
pub fn disconnected(state: &AppState, user_id: i64, conn: u64) {
    let mut inner = state.calls.inner.lock().unwrap();
    let Some(call_id) = inner.by_user.get(&user_id).cloned() else {
        return;
    };
    let bound = inner.calls.get(&call_id).is_some_and(|c| {
        (c.caller_id == user_id && c.caller_conn == conn)
            || (c.callee_id == user_id && c.callee_conn == Some(conn))
    });
    if bound {
        if let Some(call) = inner.remove(&call_id) {
            call.notify_ended(&state.hub, &call_id, EndReason::Disconnected);
        }
    }
}

/// 把一帧语音转发给通话的另一方。没有接通的通话、不是绑定的那条连接，都直接丢掉
pub fn relay_audio(state: &AppState, user_id: i64, conn: u64, data: Bytes) {
    if data.len() > MAX_AUDIO_FRAME {
        return;
    }
    let inner = state.calls.inner.lock().unwrap();
    let Some(call) = inner.by_user.get(&user_id).and_then(|id| inner.calls.get(id)) else {
        return;
    };
    let Some(callee_conn) = call.callee_conn else {
        return;
    };
    let peer = if call.caller_id == user_id && call.caller_conn == conn {
        (call.callee_id, callee_conn)
    } else if call.callee_id == user_id && callee_conn == conn {
        (call.caller_id, call.caller_conn)
    } else {
        return;
    };
    state.hub.send_to_conn(peer.0, peer.1, Message::Binary(data));
}
