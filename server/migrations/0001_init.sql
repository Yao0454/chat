CREATE TABLE users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT    NOT NULL,
    created_at    INTEGER NOT NULL
);

CREATE TABLE invite_codes (
    code       TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    used_by    INTEGER REFERENCES users(id),
    used_at    INTEGER
);

CREATE TABLE sessions (
    token      TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    created_at INTEGER NOT NULL
);

-- kind: 'direct' 一对一 / 'group' 群聊（第三步再用）
-- direct_key: 一对一会话的唯一键 "小id:大id"，保证两个人之间只有一个会话
-- last_seq: 这个会话里最后一条消息的序号，用来分配下一个 seq
CREATE TABLE conversations (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT    NOT NULL CHECK (kind IN ('direct', 'group')),
    direct_key TEXT    UNIQUE,
    title      TEXT,
    last_seq   INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

CREATE TABLE conversation_members (
    conversation_id INTEGER NOT NULL REFERENCES conversations(id),
    user_id         INTEGER NOT NULL REFERENCES users(id),
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX idx_members_user ON conversation_members(user_id);

-- seq: 会话内严格递增的序号，客户端只按它排序和做增量同步
-- client_id: 客户端生成的 UUID，用来去重（网络重发不会产生重复消息）
CREATE TABLE messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id),
    seq             INTEGER NOT NULL,
    sender_id       INTEGER NOT NULL REFERENCES users(id),
    client_id       TEXT    NOT NULL,
    body            TEXT    NOT NULL,
    created_at      INTEGER NOT NULL,
    UNIQUE (conversation_id, seq),
    UNIQUE (sender_id, client_id)
);
