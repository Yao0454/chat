import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    enum Phase { case restoring, loggedOut, loggedIn }

    var phase: Phase = .restoring
    var serverURLString = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:8080"
    var me: UserDTO?
    var users: [UserDTO] = []
    var conversations: [ConversationDTO] = []
    var items: [Int64: [ChatItem]] = [:]
    var isConnected = false
    var errorMessage: String?
    let call = CallController()

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var socket: ChatSocket?
    /// 每个会话里"连续收到的最大 seq"，重连后从这里开始增量同步
    @ObservationIgnored private var syncedSeq: [Int64: Int64] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        // 退出 App 前把还没写盘的改动存下来
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCacheNow() }
        }
    }

    // MARK: - 登录

    func restore() async {
        guard let token = Keychain.load(account: "token"),
              let url = URL(string: serverURLString) else {
            phase = .loggedOut
            return
        }
        let client = APIClient(baseURL: url, token: token)
        do {
            let user: UserDTO = try await client.get("api/me")
            startSession(client: client, user: user)
        } catch let error as APIError where error.isUnauthorized {
            endSession(keepCache: true)
            errorMessage = error.localizedDescription
        } catch {
            // 服务器暂时连不上（比如正在重启，Caddy 会回 502）：有本地记录就先离线进入，
            // WebSocket 会自己重连；如果 token 其实已经失效，握手会收到 401，到时再回登录页
            if let cache = MessageCache.load(), cache.serverURL == url.absoluteString {
                startSession(client: client, user: cache.me)
            } else {
                errorMessage = error.localizedDescription
                phase = .loggedOut
            }
        }
    }

    func login(username: String, password: String) async {
        await authenticate(path: "api/login", body: LoginBody(username: username, password: password))
    }

    func register(inviteCode: String, username: String, password: String) async {
        await authenticate(
            path: "api/register",
            body: RegisterBody(inviteCode: inviteCode, username: username, password: password)
        )
    }

    func logout() {
        // 通知服务端让 token 失效；请求失败也没关系，本地照样退出
        if let api {
            Task { try? await api.post("api/logout") }
        }
        endSession(keepCache: false)
    }

    /// token 失效或过期：回到登录页。本地记录留着，重新登录同一个账号后接着用
    private func sessionExpired() {
        saveCacheNow()
        endSession(keepCache: true)
        errorMessage = "登录已失效，请重新登录"
    }

    private func endSession(keepCache: Bool) {
        saveTask?.cancel()
        call.reset()
        call.socket = nil
        socket?.stop()
        socket = nil
        Keychain.delete(account: "token")
        if !keepCache { MessageCache.delete() }
        api = nil
        me = nil
        users = []
        conversations = []
        items = [:]
        syncedSeq = [:]
        isConnected = false
        phase = .loggedOut
    }

    private func authenticate(path: String, body: some Encodable) async {
        errorMessage = nil
        guard let url = normalizedServerURL() else {
            errorMessage = "服务器地址格式不对，例如 http://127.0.0.1:8080"
            return
        }
        do {
            let response: AuthResponse = try await APIClient(baseURL: url).post(path, body)
            UserDefaults.standard.set(url.absoluteString, forKey: "serverURL")
            serverURLString = url.absoluteString
            Keychain.save(response.token, account: "token")
            startSession(client: APIClient(baseURL: url, token: response.token), user: response.user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 列表和消息在 WebSocket 连上后刷新（见 didConnect）
    private func startSession(client: APIClient, user: UserDTO) {
        api = client
        me = user
        loadCache(serverURL: client.baseURL.absoluteString, userId: user.id)
        phase = .loggedIn

        let s = ChatSocket(url: websocketURL(for: client.baseURL), token: client.token ?? "")
        s.onEvent = { [weak self] event in self?.handle(event) }
        s.onConnectionChange = { [weak self] connected in
            self?.isConnected = connected
            if connected { self?.didConnect() } else { self?.call.connectionLost() }
        }
        s.onUnauthorized = { [weak self] in self?.sessionExpired() }
        s.onAudio = { [weak self] packet in self?.call.receiveAudio(packet) }
        socket = s
        call.socket = s
        s.start()
    }

    // MARK: - 列表

    func refreshLists() async {
        guard let api else { return }
        do {
            users = try await api.get("api/users")
            conversations = try await api.get("api/conversations")
            for conv in conversations where syncedSeq[conv.id] == nil {
                requestSync(conv.id)
            }
            scheduleSave()
        } catch is URLError {
            // 连不上服务器：状态栏已经显示"正在连接…"，连上后会再刷新
        } catch {
            report(error)
        }
    }

    func openDirect(with user: UserDTO) async -> Int64? {
        guard let api else { return nil }
        do {
            let conv: ConversationDTO = try await api.post("api/conversations/direct", OpenDirectBody(userId: user.id))
            if !conversations.contains(where: { $0.id == conv.id }) {
                conversations.append(conv)
                requestSync(conv.id)
                scheduleSave()
            }
            return conv.id
        } catch {
            report(error)
            return nil
        }
    }

    func title(for conv: ConversationDTO) -> String {
        if let title = conv.title, !title.isEmpty { return title }
        let others = conv.members.filter { $0.id != me?.id }.map(\.username)
        return others.isEmpty ? "我自己" : others.joined(separator: "、")
    }

    // MARK: - 发消息

    func send(_ text: String, to conversationId: Int64) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let me else { return }
        let item = ChatItem(
            clientId: UUID().uuidString.lowercased(),
            seq: nil,
            senderId: me.id,
            body: body,
            createdAt: .now,
            status: .pending
        )
        items[conversationId, default: []].append(item)
        socket?.send(SendCommand(clientId: item.clientId, conversationId: conversationId, body: body))
        scheduleSave()
    }

    func retry(_ item: ChatItem, in conversationId: Int64) {
        guard let i = items[conversationId]?.firstIndex(where: { $0.clientId == item.clientId }) else { return }
        items[conversationId]?[i].status = .pending
        socket?.send(SendCommand(clientId: item.clientId, conversationId: conversationId, body: item.body))
        scheduleSave()
    }

    // MARK: - 处理服务端事件

    private func didConnect() {
        // 断线期间可能有新用户注册，或者有人和我开了新会话
        Task { await refreshLists() }
        for conv in conversations {
            requestSync(conv.id)
        }
        // 重发还没被确认的消息；服务端按 client_id 去重，不会出现重复
        for (conversationId, list) in items {
            for item in list where item.status == .pending {
                socket?.send(SendCommand(clientId: item.clientId, conversationId: conversationId, body: item.body))
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .ack(_, let m), .message(let m):
            if !conversations.contains(where: { $0.id == m.conversationId }) {
                // 别人刚和我开了新会话
                Task { await refreshLists() }
            }
            upsert(m)
            sortItems(m.conversationId)
            advanceSynced(m.conversationId)
            // seq 跳号了，说明中间有消息没收到，补一下
            if m.seq > syncedSeq[m.conversationId, default: 0] {
                requestSync(m.conversationId)
            }

        case .history(let conversationId, let messages, let hasMore):
            for m in messages { upsert(m) }
            sortItems(conversationId)
            advanceSynced(conversationId)
            if hasMore { requestSync(conversationId) }

        case .callIncoming, .callAccepted, .callEnded:
            call.handle(event)
            return

        case .error(let clientId, let error):
            if let clientId, call.handleError(callId: clientId, message: error) {
                return
            }
            if let clientId {
                markFailed(clientId: clientId, reason: error)
            } else {
                errorMessage = error
            }

        case .unknown:
            break
        }
        scheduleSave()
    }

    private func requestSync(_ conversationId: Int64) {
        socket?.send(SyncCommand(conversationId: conversationId, afterSeq: syncedSeq[conversationId] ?? 0))
    }

    private func upsert(_ m: MessageDTO) {
        var list = items[m.conversationId, default: []]
        if let i = list.firstIndex(where: { $0.clientId == m.clientId && $0.senderId == m.senderId }) {
            list[i] = ChatItem(m)
        } else if !list.contains(where: { $0.seq == m.seq }) {
            list.append(ChatItem(m))
        }
        items[m.conversationId] = list
    }

    /// 已确认的按 seq 排，还在发送中的排在最后
    private func sortItems(_ conversationId: Int64) {
        items[conversationId]?.sort {
            ($0.seq ?? .max, $0.createdAt) < ($1.seq ?? .max, $1.createdAt)
        }
    }

    private func advanceSynced(_ conversationId: Int64) {
        let seqs = Set(items[conversationId, default: []].compactMap(\.seq))
        var s = syncedSeq[conversationId] ?? 0
        while seqs.contains(s + 1) { s += 1 }
        syncedSeq[conversationId] = s
    }

    private func markFailed(clientId: String, reason: String) {
        for (conversationId, list) in items {
            // 已经保存成功（有 seq）的消息不再标成失败
            if let i = list.firstIndex(where: { $0.clientId == clientId && $0.seq == nil }) {
                items[conversationId]?[i].status = .failed(reason)
                return
            }
        }
    }

    private func report(_ error: Error) {
        if let e = error as? APIError, e.isUnauthorized {
            sessionExpired()
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 本地缓存

    /// 只恢复同一个服务器、同一个账号的记录，否则丢掉
    private func loadCache(serverURL: String, userId: Int64) {
        guard let cache = MessageCache.load() else { return }
        guard cache.serverURL == serverURL, cache.me.id == userId else {
            MessageCache.delete()
            return
        }
        users = cache.users
        conversations = cache.conversations
        items = cache.items
        syncedSeq = cache.syncedSeq
    }

    /// 改动很频繁（收一页历史就是几百条），攒 1 秒再写一次盘
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveCacheNow()
        }
    }

    private func saveCacheNow() {
        saveTask?.cancel()
        guard let me, let api else { return }
        MessageCache.save(CacheSnapshot(
            serverURL: api.baseURL.absoluteString,
            me: me,
            users: users,
            conversations: conversations,
            items: items,
            syncedSeq: syncedSeq
        ))
    }

    // MARK: - 工具

    private func normalizedServerURL() -> URL? {
        var s = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private func websocketURL(for base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        return comps.url!
    }
}
