use std::{
    collections::HashMap,
    str::FromStr,
    time::{SystemTime, UNIX_EPOCH},
};

use argon2::password_hash::rand_core::{OsRng, RngCore};
use serde::Serialize;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
    FromRow, SqlitePool,
};

pub async fn connect(url: &str) -> Result<SqlitePool, sqlx::Error> {
    let opts = SqliteConnectOptions::from_str(url)?
        .create_if_missing(true)
        .foreign_keys(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(opts)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(pool)
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

pub fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    OsRng.fill_bytes(&mut buf);
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

pub async fn create_invite(db: &SqlitePool) -> Result<String, sqlx::Error> {
    let code = random_hex(5);
    sqlx::query("INSERT INTO invite_codes (code, created_at) VALUES (?, ?)")
        .bind(&code)
        .bind(now_ms())
        .execute(db)
        .await?;
    Ok(code)
}

// ---------- 数据结构 ----------

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct User {
    pub id: i64,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct MessageRow {
    pub id: i64,
    pub conversation_id: i64,
    pub seq: i64,
    pub sender_id: i64,
    pub client_id: String,
    pub body: String,
    pub created_at: i64,
}

#[derive(Debug, Serialize)]
pub struct Conversation {
    pub id: i64,
    pub kind: String,
    pub title: Option<String>,
    pub last_seq: i64,
    pub members: Vec<User>,
}

const MESSAGE_COLUMNS: &str =
    "id, conversation_id, seq, sender_id, client_id, body, created_at";

// ---------- 会话 ----------

pub async fn is_member(db: &SqlitePool, conversation_id: i64, user_id: i64) -> Result<bool, sqlx::Error> {
    let row = sqlx::query_scalar::<_, i64>(
        "SELECT 1 FROM conversation_members WHERE conversation_id = ? AND user_id = ?",
    )
    .bind(conversation_id)
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    Ok(row.is_some())
}

pub async fn member_ids(db: &SqlitePool, conversation_id: i64) -> Result<Vec<i64>, sqlx::Error> {
    sqlx::query_scalar::<_, i64>("SELECT user_id FROM conversation_members WHERE conversation_id = ?")
        .bind(conversation_id)
        .fetch_all(db)
        .await
}

pub async fn conversations_for_user(db: &SqlitePool, user_id: i64) -> Result<Vec<Conversation>, sqlx::Error> {
    #[derive(FromRow)]
    struct ConvRow {
        id: i64,
        kind: String,
        title: Option<String>,
        last_seq: i64,
    }
    #[derive(FromRow)]
    struct MemberRow {
        conversation_id: i64,
        id: i64,
        username: String,
    }

    let convs = sqlx::query_as::<_, ConvRow>(
        "SELECT c.id, c.kind, c.title, c.last_seq
         FROM conversations c
         JOIN conversation_members m ON m.conversation_id = c.id
         WHERE m.user_id = ?
         ORDER BY c.id",
    )
    .bind(user_id)
    .fetch_all(db)
    .await?;

    let members = sqlx::query_as::<_, MemberRow>(
        "SELECT m.conversation_id, u.id, u.username
         FROM conversation_members m
         JOIN users u ON u.id = m.user_id
         WHERE m.conversation_id IN
             (SELECT conversation_id FROM conversation_members WHERE user_id = ?)
         ORDER BY u.id",
    )
    .bind(user_id)
    .fetch_all(db)
    .await?;

    let mut by_conv: HashMap<i64, Vec<User>> = HashMap::new();
    for m in members {
        by_conv.entry(m.conversation_id).or_default().push(User {
            id: m.id,
            username: m.username,
        });
    }

    Ok(convs
        .into_iter()
        .map(|c| Conversation {
            members: by_conv.remove(&c.id).unwrap_or_default(),
            id: c.id,
            kind: c.kind,
            title: c.title,
            last_seq: c.last_seq,
        })
        .collect())
}

/// 找到或创建两个人之间的一对一会话，返回会话 id
pub async fn open_direct(db: &SqlitePool, me: i64, other: i64) -> Result<i64, sqlx::Error> {
    let (a, b) = if me < other { (me, other) } else { (other, me) };
    let key = format!("{a}:{b}");

    let mut tx = db.begin().await?;
    sqlx::query(
        "INSERT OR IGNORE INTO conversations (kind, direct_key, created_at) VALUES ('direct', ?, ?)",
    )
    .bind(&key)
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;

    let id = sqlx::query_scalar::<_, i64>("SELECT id FROM conversations WHERE direct_key = ?")
        .bind(&key)
        .fetch_one(&mut *tx)
        .await?;

    for uid in [a, b] {
        sqlx::query(
            "INSERT OR IGNORE INTO conversation_members (conversation_id, user_id) VALUES (?, ?)",
        )
        .bind(id)
        .bind(uid)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(id)
}

// ---------- 消息 ----------

async fn find_by_client_id(
    db: &SqlitePool,
    sender_id: i64,
    client_id: &str,
) -> Result<Option<MessageRow>, sqlx::Error> {
    sqlx::query_as::<_, MessageRow>(&format!(
        "SELECT {MESSAGE_COLUMNS} FROM messages WHERE sender_id = ? AND client_id = ?"
    ))
    .bind(sender_id)
    .bind(client_id)
    .fetch_optional(db)
    .await
}

/// 写入一条消息。返回 (消息, 是否新写入)。
/// 同一个发送者的同一个 client_id 只会写入一次，重发时直接返回已有的那条。
pub async fn insert_message(
    db: &SqlitePool,
    conversation_id: i64,
    sender_id: i64,
    client_id: &str,
    body: &str,
) -> Result<(MessageRow, bool), sqlx::Error> {
    if let Some(m) = find_by_client_id(db, sender_id, client_id).await? {
        return Ok((m, false));
    }

    match insert_new_message(db, conversation_id, sender_id, client_id, body).await {
        Ok(m) => Ok((m, true)),
        // 同一条消息的两次发送同时到达（比如重连后的重发和旧连接上还没处理完的原始请求），
        // 另一次抢先写入了，这里就当作重发处理
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            let m = find_by_client_id(db, sender_id, client_id)
                .await?
                .ok_or(sqlx::Error::RowNotFound)?;
            Ok((m, false))
        }
        Err(e) => Err(e),
    }
}

async fn insert_new_message(
    db: &SqlitePool,
    conversation_id: i64,
    sender_id: i64,
    client_id: &str,
    body: &str,
) -> Result<MessageRow, sqlx::Error> {
    let mut tx = db.begin().await?;
    // 原子地拿到下一个 seq（SQLite 同一时间只有一个写事务，所以不会撞号）
    let seq = sqlx::query_scalar::<_, i64>(
        "UPDATE conversations SET last_seq = last_seq + 1 WHERE id = ? RETURNING last_seq",
    )
    .bind(conversation_id)
    .fetch_one(&mut *tx)
    .await?;

    let created_at = now_ms();
    let id = sqlx::query_scalar::<_, i64>(
        "INSERT INTO messages (conversation_id, seq, sender_id, client_id, body, created_at)
         VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
    )
    .bind(conversation_id)
    .bind(seq)
    .bind(sender_id)
    .bind(client_id)
    .bind(body)
    .bind(created_at)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(MessageRow {
        id,
        conversation_id,
        seq,
        sender_id,
        client_id: client_id.to_string(),
        body: body.to_string(),
        created_at,
    })
}

pub async fn messages_after(
    db: &SqlitePool,
    conversation_id: i64,
    after_seq: i64,
    limit: i64,
) -> Result<Vec<MessageRow>, sqlx::Error> {
    sqlx::query_as::<_, MessageRow>(&format!(
        "SELECT {MESSAGE_COLUMNS} FROM messages
         WHERE conversation_id = ? AND seq > ?
         ORDER BY seq LIMIT ?"
    ))
    .bind(conversation_id)
    .bind(after_seq)
    .bind(limit)
    .fetch_all(db)
    .await
}
