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
    pub read_states: Vec<ReadState>,
}

/// 某个成员读到了哪条消息
#[derive(Debug, Clone, Serialize)]
pub struct ReadState {
    pub user_id: i64,
    pub last_read_seq: i64,
    pub last_read_at: Option<i64>,
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

/// 一对一会话里的另一个人；不是一对一会话或者自己不在里面时返回 None
pub async fn direct_peer(
    db: &SqlitePool,
    conversation_id: i64,
    user_id: i64,
) -> Result<Option<i64>, sqlx::Error> {
    sqlx::query_scalar::<_, i64>(
        "SELECT other.user_id
         FROM conversations c
         JOIN conversation_members me ON me.conversation_id = c.id AND me.user_id = ?
         JOIN conversation_members other ON other.conversation_id = c.id AND other.user_id != ?
         WHERE c.id = ? AND c.kind = 'direct'",
    )
    .bind(user_id)
    .bind(user_id)
    .bind(conversation_id)
    .fetch_optional(db)
    .await
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
        last_read_seq: i64,
        last_read_at: Option<i64>,
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
        "SELECT m.conversation_id, u.id, u.username, m.last_read_seq, m.last_read_at
         FROM conversation_members m
         JOIN users u ON u.id = m.user_id
         WHERE m.conversation_id IN
             (SELECT conversation_id FROM conversation_members WHERE user_id = ?)
         ORDER BY u.id",
    )
    .bind(user_id)
    .fetch_all(db)
    .await?;

    let mut by_conv: HashMap<i64, (Vec<User>, Vec<ReadState>)> = HashMap::new();
    for m in members {
        let (users, reads) = by_conv.entry(m.conversation_id).or_default();
        reads.push(ReadState {
            user_id: m.id,
            last_read_seq: m.last_read_seq,
            last_read_at: m.last_read_at,
        });
        users.push(User {
            id: m.id,
            username: m.username,
        });
    }

    Ok(convs
        .into_iter()
        .map(|c| {
            let (members, read_states) = by_conv.remove(&c.id).unwrap_or_default();
            Conversation {
                members,
                read_states,
            id: c.id,
                kind: c.kind,
                title: c.title,
                last_seq: c.last_seq,
            }
        })
        .collect())
}

/// 记录 user 读到了 seq（不会往回退，也不会超过会话里最后一条）。
/// 真的往前推进了才返回新的状态，用来决定要不要通知其他人
pub async fn mark_read(
    db: &SqlitePool,
    conversation_id: i64,
    user_id: i64,
    seq: i64,
) -> Result<Option<ReadState>, sqlx::Error> {
    let now = now_ms();
    let updated = sqlx::query_scalar::<_, i64>(
        "UPDATE conversation_members
         SET last_read_seq = MIN(?1, (SELECT last_seq FROM conversations WHERE id = ?2)),
             last_read_at = ?3
         WHERE conversation_id = ?2 AND user_id = ?4
           AND last_read_seq < MIN(?1, (SELECT last_seq FROM conversations WHERE id = ?2))
         RETURNING last_read_seq",
    )
    .bind(seq)
    .bind(conversation_id)
    .bind(now)
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    Ok(updated.map(|last_read_seq| ReadState {
        user_id,
        last_read_seq,
        last_read_at: Some(now),
    }))
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
