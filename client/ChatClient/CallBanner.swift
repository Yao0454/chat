import SwiftUI

/// 窗口顶部的通话浮条：呼叫中、来电、通话中、已结束
struct CallBanner: View {
    @Environment(ChatStore.self) private var store
    let call: CallController.Call

    private var ringing: Bool { call.phase == .incoming || call.phase == .outgoing }

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 14) {
                avatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(call.peerName)
                        .font(.headline)
                    status
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                buttons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 420)
            .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: call.phase)
    }

    // MARK: - 头像：响铃时有波纹，通话中对方说话时发光

    private var avatar: some View {
        ZStack {
            if ringing {
                PulseRing(color: call.phase == .incoming ? .green : .accentColor)
            }
            if call.phase == .active {
                Circle()
                    .fill(Color.green.opacity(0.35))
                    .scaleEffect(1 + CGFloat(store.call.outputLevel) * 0.4)
                    .animation(.easeOut(duration: 0.12), value: store.call.outputLevel)
            }
            AvatarView(name: call.peerName, size: 46)
        }
        .frame(width: 46, height: 46)
    }

    @ViewBuilder
    private var status: some View {
        switch call.phase {
        case .outgoing:
            Text("正在呼叫…")
        case .incoming:
            Text("邀请你语音通话")
        case .connecting:
            Text("正在接通…")
        case .active:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let start = call.connectedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Duration.seconds(context.date.timeIntervalSince(start)), format: .time(pattern: .minuteSecond))
                        }
                    }
                    LevelMeter(level: store.call.isMuted ? 0 : store.call.inputLevel)
                }
                if store.call.micSilent {
                    Text("麦克风没有声音，可能是权限失效")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("在终端运行 tccutil reset Microphone com.feng.ChatClient，然后重新打开 App 并允许麦克风")
                } else if store.call.echoCancellationOff {
                    Text("这台电脑没能开启回声消除，建议戴耳机")
                        .font(.caption)
                }
            }
        case .ended(let text):
            Text(text)
        }
    }

    // MARK: - 按钮

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch call.phase {
            case .incoming:
                CallButton(systemImage: "phone.down.fill", tint: .red, help: "拒绝") {
                    store.call.hangup()
                }
                CallButton(systemImage: "phone.fill", tint: .green, help: "接听") {
                    Task { await store.call.accept() }
                }
            case .outgoing, .connecting:
                CallButton(systemImage: "phone.down.fill", tint: .red, help: "取消") {
                    store.call.hangup()
                }
            case .active:
                CallButton(
                    systemImage: store.call.isMuted ? "mic.slash.fill" : "mic.fill",
                    tint: store.call.isMuted ? .orange : nil,
                    help: store.call.isMuted ? "取消静音" : "静音"
                ) {
                    store.call.toggleMute()
                }
                CallButton(systemImage: "phone.down.fill", tint: .red, help: "挂断") {
                    store.call.hangup()
                }
            case .ended:
                EmptyView()
            }
        }
    }
}

private struct CallButton: View {
    let systemImage: String
    let tint: Color?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: 42, height: 42)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), tint: tint, interactive: true)
        .help(help)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

/// 响铃时从头像向外扩散的波纹
private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 2)
                    .scaleEffect(expanded ? 1.7 : 1)
                    .opacity(expanded ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                        value: expanded
                    )
            }
        }
        .onAppear { expanded = true }
    }
}

/// 自己的麦克风音量：5 格竖条
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Float(i) / 5 < level ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 5 + CGFloat(i) * 2.5)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .help("你的麦克风音量")
    }
}
