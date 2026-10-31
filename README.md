# 小圈子聊天：邀请码注册 + 一对一文字聊天 + 语音通话

```
chat-app/
├── server/            Rust 服务端（axum + SQLite）
│   ├── Cargo.toml
│   ├── migrations/0001_init.sql
│   └── src/  main.rs  api.rs  auth.rs  calls.rs  db.rs  error.rs  hub.rs  ratelimit.rs  ws.rs
└── client/
    ├── ChatClient.xcodeproj   Xcode 项目（直接打开）
    ├── Info.plist             允许本地 http 连接
    └── ChatClient/            SwiftUI 源文件（项目会自动包含这个文件夹里的所有文件）
```

## 1. 跑起服务端

```bash
cd server
cargo run -- invite 2      # 生成 2 个邀请码（第一次运行会自动建库 chat.db）
cargo run                  # 启动，默认监听 127.0.0.1:8080
```

环境变量：`DATABASE_URL`（默认 `sqlite://chat.db`）、`BIND`（默认 `127.0.0.1:8080`）、`RUST_LOG`。

## 2. 打开 Xcode 项目

```bash
open client/ChatClient.xcodeproj
```

直接按 ⌘R 运行。项目已经配好：macOS 14+、App Sandbox 打开且允许对外连接（Outgoing Connections）、本地开发允许 http（`Info.plist` 里的 `Allow Local Networking`）、用本机临时签名（Sign to Run Locally）。

以后在 `client/ChatClient/` 里新增的 `.swift` 文件会自动进项目，不用再拖。

运行后用邀请码注册一个账号。

## 3. 一台电脑上测试两个人聊天

App 用钥匙串保存登录状态，所以第二个账号用命令行来扮演：

```bash
# 用第二个邀请码注册用户 bob，记下返回的 token
curl -s localhost:8080/api/register -H 'Content-Type: application/json' \
  -d '{"invite_code":"邀请码","username":"bob","password":"12345678"}'

# 和 id=1 的用户开会话，记下返回的会话 id
curl -s localhost:8080/api/conversations/direct -H 'Authorization: Bearer TOKEN' \
  -H 'Content-Type: application/json' -d '{"user_id":1}'

# 连上 WebSocket（brew install websocat），然后粘贴一行 JSON 发消息
websocat -H 'Authorization: Bearer TOKEN' ws://127.0.0.1:8080/ws
{"type":"send","client_id":"test-1","conversation_id":1,"body":"你好，我是 bob"}
```

App 里会立刻出现这条消息；在 App 里回复，websocat 那边也会收到。

## 4. 语音通话

在一对一会话里点工具栏的电话按钮发起通话，对方窗口顶部会弹出来电浮条并响铃（App 在后台时 Dock 图标会跳动），可以接听、拒绝；通话中可以静音、挂断。第一次通话时系统会询问麦克风权限。

- 声音经过服务器中转，只要双方都能连上服务器就能通话，不需要额外的 TURN 服务器。
- 编码用系统自带的 Opus（24 kbps，20ms 一帧），每路通话单向约 25–30 kbps。
- 开了系统的回声消除，用外放也不会把对方的声音传回去。
- 同一时间每人只能有一个通话；对方在多台设备上登录时每台都会响铃，哪台接听就用哪台。
- 响铃 45 秒无人接听自动结束；任何一方掉线，通话随即结束。
- 语音走 WebSocket（TCP），网络卡顿后积压的语音超过 300ms 会被丢弃，避免延迟越来越大。

测试需要两台 Mac 分别登录两个账号（同一台电脑上 App 只能登录一个账号）。信令协议写在 `server/src/calls.rs` 开头的注释里。

## 5. 部署到 VPS

把 `cargo build --release` 得到的二进制放到服务器上，前面用 Caddy 自动加 HTTPS（WebSocket 会自动转发）：

```
chat.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

App 里的服务器地址填 `https://chat.example.com`。

服务端要保持默认的只监听 `127.0.0.1`。限速按客户端 IP 计数：对端是本机时，服务端认为前面是 Caddy，采信 `X-Forwarded-For`；如果改成直接监听公网地址，伪造的 `X-Forwarded-For` 不会被采信，但也就没有 HTTPS 了。

## 登录与安全

- 登录状态 30 天后失效，需要重新登录。App 里"退出登录"会调用 `POST /api/logout` 让服务端的 token 立即失效。
- token 失效时（过期、在别处被退出），App 会回到登录页并提示"登录已失效"；服务器只是暂时连不上（比如重启时 Caddy 回 502）不会被登出。
- 登录和注册共用一个限速：每个 IP 每分钟最多 10 次，超出返回 429。
- 聊天记录缓存在本机 `~/Library/Containers/<App 的 Bundle ID>/Data/Library/Application Support/ChatClient/cache.json`，下次启动先显示缓存，只同步之后的新消息；服务器连不上时也能离线打开看以前的消息。退出登录时缓存会删除。

## 协议要点

- 客户端给每条消息生成 UUID（client_id），服务端按它去重，所以断线重发不会重复。
- 服务端给每个会话分配递增的 seq，客户端只按 seq 排序。
- 重连后客户端发 `{"type":"sync","conversation_id":N,"after_seq":最后连续收到的 seq}`，服务端补发之后的消息（每页 200 条）。
- 收到的 seq 跳号时，客户端会自动请求补齐。
