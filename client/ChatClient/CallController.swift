import AppKit
import AVFoundation
import Observation

/// 一对一语音通话的状态和流程。信令走 WebSocket 文本帧，语音走二进制帧（见服务端 calls.rs）
@MainActor
@Observable
final class CallController {
    enum Phase: Equatable {
        case outgoing        // 我打出去，等对方接
        case incoming        // 别人打给我，正在响铃
        case connecting      // 我点了接听，等服务端确认
        case active          // 通话中
        case ended(String)   // 已结束，显示一会儿原因再消失
    }

    struct Call: Equatable {
        let id: String
        let conversationId: Int64
        let peerName: String
        let isOutgoing: Bool
        var phase: Phase
        var connectedAt: Date?
    }

    private(set) var current: Call?
    private(set) var isMuted = false
    /// 这台电脑上没能开启回声消除，界面上提示戴耳机
    private(set) var echoCancellationOff = false
    /// 通话中的音量（0...1），界面画音量条
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0
    /// 麦克风完全没有信号，多半是权限失效
    private(set) var micSilent = false

    /// 来电开始响铃（会话 id、来电人），用来在 App 不在前台时发通知
    @ObservationIgnored var onIncomingCall: ((Int64, String) -> Void)?
    @ObservationIgnored var onRingingStopped: (() -> Void)?

    /// 正在呼叫、响铃或通话中（已结束、正在显示原因的不算）
    var isBusy: Bool {
        guard let current else { return false }
        if case .ended = current.phase { return false }
        return true
    }

    @ObservationIgnored weak var socket: ChatSocket?
    @ObservationIgnored private var engine: VoiceEngine?
    @ObservationIgnored private let ringer = Ringer()
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private static let micDeniedText = "没有麦克风权限，请到 系统设置 → 隐私与安全性 → 麦克风 里允许 ChatClient"

    // MARK: - 用户操作

    func start(conversationId: Int64, peerName: String) async {
        guard !isBusy, socket?.isConnected == true else { return }
        let id = UUID().uuidString.lowercased()
        guard await microphoneAllowed() else {
            current = Call(id: id, conversationId: conversationId, peerName: peerName, isOutgoing: true, phase: .outgoing)
            finish(Self.micDeniedText, showFor: 6)
            return
        }
        guard !isBusy else { return }   // 等权限弹窗的时候可能来了电话
        dismissTask?.cancel()
        current = Call(id: id, conversationId: conversationId, peerName: peerName, isOutgoing: true, phase: .outgoing)
        isMuted = false
        socket?.send(CallInviteCommand(callId: id, conversationId: conversationId))
        ringer.playRingback()
    }

    func accept() async {
        guard let call = current, call.phase == .incoming else { return }
        stopRinging()
        guard await microphoneAllowed() else {
            socket?.send(CallCommand(type: "call_hangup", callId: call.id))
            finish(Self.micDeniedText, showFor: 6)
            return
        }
        guard current?.id == call.id, current?.phase == .incoming else { return }
        current?.phase = .connecting
        socket?.send(CallCommand(type: "call_accept", callId: call.id))
    }

    /// 拒绝、取消或挂断
    func hangup() {
        guard let call = current, isBusy else { return }
        socket?.send(CallCommand(type: "call_hangup", callId: call.id))
        finish(call.phase == .incoming ? "已拒绝" : "通话结束")
    }

    func toggleMute() {
        isMuted.toggle()
        engine?.isMuted = isMuted
    }

    // MARK: - 服务端事件

    func handle(_ event: ServerEvent) {
        switch event {
        case .callIncoming(let id, let conversationId, let from):
            // 服务端保证同一时间只有一个通话；这里只是覆盖掉还在显示"已结束"的上一个
            guard !isBusy else { return }
            dismissTask?.cancel()
            current = Call(id: id, conversationId: conversationId, peerName: from.username, isOutgoing: false, phase: .incoming)
            isMuted = false
            startRinging()
            onIncomingCall?(conversationId, from.username)

        case .callAccepted(let id):
            guard current?.id == id, isBusy else { return }
            stopRinging()
            current?.phase = .active
            current?.connectedAt = .now
            startAudio()

        case .callEnded(let id, let reason):
            guard let call = current, call.id == id, isBusy else { return }
            finish(Self.describe(reason, call: call))

        default:
            break
        }
    }

    /// 服务端拒绝了通话请求（比如自己已经在通话中）。是这个通话的错误就返回 true
    func handleError(callId: String, message: String) -> Bool {
        guard current?.id == callId else { return false }
        if isBusy { finish(message) }
        return true
    }

    func receiveAudio(_ packet: Data) {
        engine?.play(packet)
    }

    /// 和服务器断开了：服务端那边会结束这个通话，本地也跟着结束
    func connectionLost() {
        if isBusy { finish("网络断开，通话已结束") }
    }

    /// 退出登录时直接清掉，不显示原因
    func reset() {
        stopRinging()
        stopAudio()
        dismissTask?.cancel()
        current = nil
    }

    // MARK: - 内部

    private static func describe(_ reason: String, call: Call) -> String {
        switch reason {
        case "hangup": call.phase == .incoming ? "对方已取消" : "对方已挂断"
        case "rejected": call.isOutgoing ? "对方拒绝了通话" : "已拒绝"
        case "busy": "对方正在通话中"
        case "offline": "对方不在线"
        case "timeout": call.isOutgoing ? "对方无人接听" : "未接来电"
        case "disconnected": "对方网络断开，通话已结束"
        case "answered_elsewhere": "已在其他设备上接听"
        default: "通话结束"
        }
    }

    private func finish(_ text: String, showFor seconds: Double = 3) {
        stopRinging()
        stopAudio()
        guard let id = current?.id else { return }
        current?.phase = .ended(text)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    private func startAudio() {
        let engine = VoiceEngine()
        engine.isMuted = isMuted
        engine.onPacket = { [weak self] packet in
            Task { @MainActor [weak self] in self?.socket?.sendAudio(packet) }
        }
        do {
            try engine.start()
            self.engine = engine
            echoCancellationOff = !engine.echoCancellation
            startLevelUpdates()
        } catch {
            if let id = current?.id {
                socket?.send(CallCommand(type: "call_hangup", callId: id))
            }
            finish("无法打开麦克风：\(error.localizedDescription)", showFor: 6)
        }
    }

    private func stopAudio() {
        levelTask?.cancel()
        levelTask = nil
        engine?.stop()
        engine = nil
        echoCancellationOff = false
        inputLevel = 0
        outputLevel = 0
        micSilent = false
    }

    /// 每 80ms 从音频引擎取一次音量
    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine else { return }
                let levels = engine.levels
                self.inputLevel = levels.input
                self.outputLevel = levels.output
                self.micSilent = !self.isMuted && engine.micSilent
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// 来电时循环响铃，App 在后台时让 Dock 图标跳动
    private func startRinging() {
        NSApp.requestUserAttention(.criticalRequest)
        ringer.playIncoming()
    }

    /// 停止来电铃声或去电回铃音
    private func stopRinging() {
        ringer.stop()
        onRingingStopped?()
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
