import SwiftUI

/// iMessage 样式的气泡：圆角矩形，一组消息的最后一条带小尾巴
nonisolated struct BubbleShape: Shape {
    let isMine: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(17, rect.height / 2)
        let body = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        guard hasTail else { return body }

        // 先按右下角的尾巴画，是对方的消息再左右翻转
        let w = rect.width, h = rect.height
        var tail = Path()
        tail.move(to: CGPoint(x: w - 1, y: h - radius))
        tail.addQuadCurve(to: CGPoint(x: w + 5, y: h), control: CGPoint(x: w - 1, y: h - 3))
        tail.addQuadCurve(to: CGPoint(x: w - 9, y: h), control: CGPoint(x: w - 3, y: h - 1.5))
        tail.addLine(to: CGPoint(x: w - radius, y: h))
        tail.addLine(to: CGPoint(x: w - radius, y: h - radius))
        tail.closeSubpath()
        if !isMine {
            tail = tail.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
        }
        return body.union(tail.offsetBy(dx: rect.minX, dy: rect.minY))
    }
}

struct MessageBubble: View {
    let item: ChatItem
    let isMine: Bool
    let hasTail: Bool
    var onRetry: () -> Void

    private var failed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine {
                Spacer(minLength: 72)
                if failed {
                    Button(action: onRetry) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("发送失败，点击重新发送")
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Text(item.body)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    if isMine {
                        BubbleShape(isMine: true, hasTail: hasTail).fill(Palette.bubbleBlue)
                    } else {
                        BubbleShape(isMine: false, hasTail: hasTail).fill(Palette.bubbleGray)
                    }
                }
                // 尾巴画在气泡外面，留出位置让一组气泡左右对齐
                .padding(isMine ? .trailing : .leading, 5)
                .opacity(item.status == .pending ? 0.65 : 1)
                .help(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .contextMenu {
                    Button("拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.body, forType: .string)
                    }
                }

            if !isMine { Spacer(minLength: 72) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: failed)
    }
}
