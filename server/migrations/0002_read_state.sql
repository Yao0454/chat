-- 每个成员读到了会话里的哪条消息：用来显示"已读"和计算未读数
ALTER TABLE conversation_members ADD COLUMN last_read_seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE conversation_members ADD COLUMN last_read_at  INTEGER;
