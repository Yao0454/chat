use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

use crate::{
    auth::{self, AuthUser},
    db::{self, Conversation, User},
    error::{AppError, AppResult},
    ratelimit::ClientIp,
    AppState,
};

#[derive(Deserialize)]
pub struct RegisterReq {
    invite_code: String,
    username: String,
    password: String,
}

#[derive(Deserialize)]
pub struct LoginReq {
    username: String,
    password: String,
}

#[derive(Serialize)]
pub struct AuthResp {
    token: String,
    user: User,
}

#[derive(Deserialize)]
pub struct OpenDirectReq {
    user_id: i64,
}

fn validate_username(name: &str) -> AppResult<()> {
    let len = name.chars().count();
    let ok_chars = name.chars().all(|c| c.is_alphanumeric() || c == '_');
    if !(2..=32).contains(&len) || !ok_chars {
        return Err(AppError::BadRequest(
            "用户名需要 2–32 个字符，只能包含字母、数字和下划线".into(),
        ));
    }
    Ok(())
}

pub async fn register(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Json(req): Json<RegisterReq>,
) -> AppResult<Json<AuthResp>> {
    if !state.auth_limiter.check(ip) {
        return Err(AppError::TooManyRequests);
    }
    let username = req.username.trim().to_string();
    let invite_code = req.invite_code.trim().to_string();
    validate_username(&username)?;
    if req.password.chars().count() < 8 {
        return Err(AppError::BadRequest("密码至少需要 8 位".into()));
    }

    // 先便宜地检查一下邀请码，免得乱填的请求也要算一遍 Argon2
    let invite_ok = sqlx::query_scalar::<_, i64>(
        "SELECT 1 FROM invite_codes WHERE code = ? AND used_at IS NULL",
    )
    .bind(&invite_code)
    .fetch_optional(&state.db)
    .await?
    .is_some();
    if !invite_ok {
        return Err(AppError::BadRequest("邀请码无效或已被使用".into()));
    }

    let hash = auth::hash_password(req.password).await?;
    let now = db::now_ms();

    // 提前 return 时 tx 会被 drop，自动回滚，邀请码不会被白白用掉
    let mut tx = state.db.begin().await?;

    let claimed = sqlx::query(
        "UPDATE invite_codes SET used_at = ? WHERE code = ? AND used_at IS NULL",
    )
    .bind(now)
    .bind(&invite_code)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if claimed != 1 {
        return Err(AppError::BadRequest("邀请码无效或已被使用".into()));
    }

    let user_id = match sqlx::query_scalar::<_, i64>(
        "INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?) RETURNING id",
    )
    .bind(&username)
    .bind(&hash)
    .bind(now)
    .fetch_one(&mut *tx)
    .await
    {
        Ok(id) => id,
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Err(AppError::Conflict("这个用户名已经有人用了".into()));
        }
        Err(e) => return Err(e.into()),
    };

    sqlx::query("UPDATE invite_codes SET used_by = ? WHERE code = ?")
        .bind(user_id)
        .bind(&invite_code)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    let token = auth::create_session(&state.db, user_id).await?;
    Ok(Json(AuthResp {
        token,
        user: User { id: user_id, username },
    }))
}

pub async fn login(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Json(req): Json<LoginReq>,
) -> AppResult<Json<AuthResp>> {
    if !state.auth_limiter.check(ip) {
        return Err(AppError::TooManyRequests);
    }

    #[derive(FromRow)]
    struct Row {
        id: i64,
        username: String,
        password_hash: String,
    }

    let bad = || AppError::BadRequest("用户名或密码不正确".into());

    let row = sqlx::query_as::<_, Row>(
        "SELECT id, username, password_hash FROM users WHERE username = ?",
    )
    .bind(req.username.trim())
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(bad)?;

    if !auth::verify_password(req.password, row.password_hash).await {
        return Err(bad());
    }

    let token = auth::create_session(&state.db, row.id).await?;
    Ok(Json(AuthResp {
        token,
        user: User {
            id: row.id,
            username: row.username,
        },
    }))
}

/// 让当前 token 失效。token 本来就无效时也返回成功，客户端不用区分
pub async fn logout(State(state): State<AppState>, headers: HeaderMap) -> AppResult<StatusCode> {
    if let Some(token) = auth::bearer_token(&headers) {
        auth::delete_session(&state.db, token).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn me(AuthUser(user): AuthUser) -> Json<User> {
    Json(user)
}

pub async fn list_users(
    State(state): State<AppState>,
    AuthUser(_): AuthUser,
) -> AppResult<Json<Vec<User>>> {
    let users = sqlx::query_as::<_, User>("SELECT id, username FROM users ORDER BY username")
        .fetch_all(&state.db)
        .await?;
    Ok(Json(users))
}

pub async fn list_conversations(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> AppResult<Json<Vec<Conversation>>> {
    Ok(Json(db::conversations_for_user(&state.db, user.id).await?))
}

pub async fn open_direct(
    State(state): State<AppState>,
    AuthUser(me): AuthUser,
    Json(req): Json<OpenDirectReq>,
) -> AppResult<Json<Conversation>> {
    if req.user_id == me.id {
        return Err(AppError::BadRequest("不能和自己开会话".into()));
    }
    let exists = sqlx::query_scalar::<_, i64>("SELECT id FROM users WHERE id = ?")
        .bind(req.user_id)
        .fetch_optional(&state.db)
        .await?
        .is_some();
    if !exists {
        return Err(AppError::NotFound("这个用户不存在".into()));
    }

    let id = db::open_direct(&state.db, me.id, req.user_id).await?;
    let conv = db::conversations_for_user(&state.db, me.id)
        .await?
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| AppError::Internal("会话创建后未找到".into()))?;
    Ok(Json(conv))
}
