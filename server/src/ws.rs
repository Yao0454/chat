use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::Response,
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::{self, UnboundedSender};

use crate::{
    auth::AuthUser,
    calls,
    db::{self, MessageRow, User},
    AppState,
};

const MAX_BODY_CHARS: usize = 4000;
const SYNC_PAGE: i64 = 200;

// ---------- 协议 ----------
// 客户端 → 服务端
//   {"type":"send","client_id":"<uuid>","conversation_id":1,"body":"hi"}
//   {"type":"sync","conversation_id":1,"after_seq":0}
// 服务端 → 客户端
//   {"type":"ack","client_id":"...","message":{...}}      只发给发送这条消息的连接
//   {"type":"message","message":{...}}                    发给会话里所有人的所有连接（包括发送者）
//   {"type":"history","conversation_id":1,"messages":[...],"has_more":false}
//   {"type":"error","client_id":null,"error":"..."}       client_id 是出错的消息或通话的 id
// 语音通话的消息见 calls.rs

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMsg {
    Send {
        client_id: String,
        conversation_id: i64,
        body: String,
    },
    Sync {
        conversation_id: i64,
        after_seq: i64,
    },
    CallInvite {
        call_id: String,
        conversation_id: i64,
    },
    CallAccept {
        call_id: String,
    },
    CallHangup {
        call_id: String,
    },
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMsg {
    Ack {
        client_id: String,
        message: MessageRow,
    },
    Message {
        message: MessageRow,
    },
    History {
        conversation_id: i64,
        messages: Vec<MessageRow>,
        has_more: bool,
    },
    Error {
        client_id: Option<String>,
        error: String,
    },
}

fn reply(tx: &UnboundedSender<Message>, msg: &ServerMsg) {
    if let Ok(text) = serde_json::to_string(msg) {
        let _ = tx.send(Message::Text(text.into()));
    }
}

fn send_error(tx: &UnboundedSender<Message>, client_id: Option<&str>, error: &str) {
    reply(
        tx,
        &ServerMsg::Error {
            client_id: client_id.map(str::to_string),
            error: error.to_string(),
        },
    );
}

// ---------- 连接处理 ----------

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Response {
    ws.max_message_size(64 * 1024)
        .on_upgrade(move |socket| handle_socket(socket, state, user))
}

async fn handle_socket(socket: WebSocket, state: AppState, user: User) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let conn_id = state.hub.register(user.id, tx.clone());
    tracing::info!(user = %user.username, conn_id, "connected");

    // 写任务：把 channel 里的消息发到 socket
    let mut send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(msg).await.is_err() {
                break;
            }
        }
    });

    // 读循环
    loop {
        tokio::select! {
            msg = stream.next() => match msg {
                Some(Ok(Message::Text(text))) => handle_text(&state, &user, conn_id, &tx, text.as_str()).await,
                Some(Ok(Message::Binary(data))) => calls::relay_audio(&state, user.id, conn_id, data),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {} // ping/pong 由 axum 自动处理
            },
            _ = &mut send_task => break,
        }
    }

    calls::disconnected(&state, user.id, conn_id);
    state.hub.unregister(user.id, conn_id);
    send_task.abort();
    tracing::info!(user = %user.username, conn_id, "disconnected");
}

async fn handle_text(
    state: &AppState,
    user: &User,
    conn_id: u64,
    tx: &UnboundedSender<Message>,
    text: &str,
) {
    match serde_json::from_str::<ClientMsg>(text) {
        Ok(ClientMsg::Send {
            client_id,
            conversation_id,
            body,
        }) => handle_send(state, user, tx, client_id, conversation_id, body).await,
        Ok(ClientMsg::Sync {
            conversation_id,
            after_seq,
        }) => handle_sync(state, user, tx, conversation_id, after_seq).await,
        Ok(ClientMsg::CallInvite {
            call_id,
            conversation_id,
        }) => {
            if let Err(e) = calls::invite(state, user, conn_id, call_id.clone(), conversation_id).await {
                send_error(tx, Some(&call_id), &e);
            }
        }
        Ok(ClientMsg::CallAccept { call_id }) => calls::accept(state, user, conn_id, &call_id),
        Ok(ClientMsg::CallHangup { call_id }) => calls::hangup(state, user, conn_id, &call_id),
        Err(e) => send_error(tx, None, &format!("无法解析消息: {e}")),
    }
}

async fn ensure_member(
    state: &AppState,
    tx: &UnboundedSender<Message>,
    conversation_id: i64,
    user_id: i64,
    client_id: Option<&str>,
) -> bool {
    match db::is_member(&state.db, conversation_id, user_id).await {
        Ok(true) => true,
        Ok(false) => {
            send_error(tx, client_id, "你不在这个会话里");
            false
        }
        Err(e) => {
            tracing::error!("is_member failed: {e}");
            send_error(tx, client_id, "服务器内部错误");
            false
        }
    }
}

async fn handle_send(
    state: &AppState,
    user: &User,
    tx: &UnboundedSender<Message>,
    client_id: String,
    conversation_id: i64,
    body: String,
) {
    let cid = Some(client_id.as_str());
    let body = body.trim();
    if client_id.is_empty() || client_id.len() > 64 {
        return send_error(tx, cid, "client_id 无效");
    }
    if body.is_empty() {
        return send_error(tx, cid, "消息不能为空");
    }
    if body.chars().count() > MAX_BODY_CHARS {
        return send_error(tx, cid, "消息太长了，最多 4000 字");
    }
    if !ensure_member(state, tx, conversation_id, user.id, cid).await {
        return;
    }

    let (message, is_new) =
        match db::insert_message(&state.db, conversation_id, user.id, &client_id, body).await {
            Ok(v) => v,
            Err(e) => {
                tracing::error!("insert_message failed: {e}");
                return send_error(tx, cid, "消息保存失败，请重试");
            }
        };

    reply(
        tx,
        &ServerMsg::Ack {
            client_id: client_id.clone(),
            message: message.clone(),
        },
    );

    // 重发的旧消息不再广播
    if !is_new {
        return;
    }
    match db::member_ids(&state.db, conversation_id).await {
        Ok(ids) => {
            if let Ok(text) = serde_json::to_string(&ServerMsg::Message { message }) {
                let msg = Message::Text(text.into());
                for uid in ids {
                    state.hub.send_to_user(uid, msg.clone());
                }
            }
        }
        Err(e) => tracing::error!("member_ids failed: {e}"),
    }
}

async fn handle_sync(
    state: &AppState,
    user: &User,
    tx: &UnboundedSender<Message>,
    conversation_id: i64,
    after_seq: i64,
) {
    if !ensure_member(state, tx, conversation_id, user.id, None).await {
        return;
    }
    // 多取一条，用来判断后面还有没有
    match db::messages_after(&state.db, conversation_id, after_seq.max(0), SYNC_PAGE + 1).await {
        Ok(mut messages) => {
            let has_more = messages.len() as i64 > SYNC_PAGE;
            messages.truncate(SYNC_PAGE as usize);
            reply(
                tx,
                &ServerMsg::History {
                    conversation_id,
                    messages,
                    has_more,
                },
            );
        }
        Err(e) => {
            tracing::error!("messages_after failed: {e}");
            send_error(tx, None, "同步消息失败");
        }
    }
}
