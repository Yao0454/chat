import Foundation

/// 管理一条 WebSocket 连接：断线自动重连（指数退避，最长 30 秒），每 25 秒 ping 一次保活。
@MainActor
final class ChatSocket {
    var onEvent: ((ServerEvent) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// 握手被服务端以 401 拒绝（token 失效），此时不再重连
    var onUnauthorized: (() -> Void)?
    /// 收到二进制帧：语音通话里对方的一帧语音
    var onAudio: ((Data) -> Void)?

    private(set) var isConnected = false

    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var retryDelay: Double = 1
    private var stopped = true

    init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    /// 未连接时直接丢弃；待发送的消息会在重连后由 ChatStore 重发
    func send(_ command: some Encodable) {
        guard isConnected, let task,
              let data = try? JSON.encoder.encode(command),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in
            // 发送失败时 receive 循环也会报错，统一在那里处理重连
        }
    }

    /// 发送一帧语音。未连接时直接丢弃，语音不需要重发
    func sendAudio(_ data: Data) {
        guard isConnected, let task else { return }
        task.send(.data(data)) { _ in }
    }

    // MARK: - 内部

    private func connect() {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = Sessions.session(for: url).webSocketTask(with: request)
        t.maximumMessageSize = 4 * 1024 * 1024 // 一页历史消息可能比较大
        task = t
        t.resume()
        receiveLoop(t)

        // 第一个 pong 回来，说明握手成功、连接可用
        t.sendPing { [weak self] error in
            let ok = error == nil
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return }
                if ok { self.didOpen(t) } else { self.didClose(t) }
            }
        }
    }

    private func didOpen(_ t: URLSessionWebSocketTask) {
        retryDelay = 1
        setConnected(true)

        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, self.task === t, !Task.isCancelled else { return }
                t.sendPing { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in self?.didClose(t) }
                }
            }
        }
    }

    private func didClose(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }
        task = nil
        t.cancel(with: .goingAway, reason: nil)
        pingTask?.cancel()
        setConnected(false)
        if (t.response as? HTTPURLResponse)?.statusCode == 401 {
            stopped = true
            onUnauthorized?()
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.stopped, self.task == nil else { return }
            self.connect()
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await t.receive()
                } catch {
                    self?.didClose(t)
                    return
                }
                guard let self, self.task === t else { return }

                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d):
                    self.onAudio?(d)
                    continue
                @unknown default: continue
                }

                do {
                    let event = try JSON.decoder.decode(ServerEvent.self, from: data)
                    self.onEvent?(event)
                } catch {
                    print("无法解析服务端消息: \(error)")
                }
            }
        }
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnectionChange?(value)
    }
}
