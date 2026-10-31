import SwiftUI

/// 窗口顶部的通话浮条：呼叫中、来电、通话中、已结束
struct CallBanner: View {
    @Environment(ChatStore.self) private var store
    let call: CallController.Call

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(call.peerName)
                    .font(.headline)
                status
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            buttons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
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
            if let start = call.connectedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(start)), format: .time(pattern: .minuteSecond))
                }
            }
        case .ended(let text):
            Text(text)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch call.phase {
        case .incoming:
            CircleButton(systemImage: "phone.down.fill", color: .red, help: "拒绝") {
                store.call.hangup()
            }
            CircleButton(systemImage: "phone.fill", color: .green, help: "接听") {
                Task { await store.call.accept() }
            }
        case .outgoing, .connecting:
            CircleButton(systemImage: "phone.down.fill", color: .red, help: "取消") {
                store.call.hangup()
            }
        case .active:
            CircleButton(
                systemImage: store.call.isMuted ? "mic.slash.fill" : "mic.fill",
                color: store.call.isMuted ? .orange : .gray,
                help: store.call.isMuted ? "取消静音" : "静音"
            ) {
                store.call.toggleMute()
            }
            CircleButton(systemImage: "phone.down.fill", color: .red, help: "挂断") {
                store.call.hangup()
            }
        case .ended:
            EmptyView()
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
