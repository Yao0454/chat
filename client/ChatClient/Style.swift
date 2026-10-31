import SwiftUI

// MARK: - 液态玻璃

extension View {
    /// macOS 26 起用液态玻璃，旧系统退回毛玻璃材质
    @ViewBuilder
    func glass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// 让里面相邻的玻璃元素融合在一起、一起变形（macOS 26 起）
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 颜色

enum Palette {
    /// iMessage 的蓝色气泡，上浅下深
    static let bubbleBlue = LinearGradient(
        colors: [Color(red: 0.24, green: 0.62, blue: 1.0), Color(red: 0.04, green: 0.49, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )

    /// 对方的灰色气泡，跟随深浅色模式
    static let bubbleGray = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })

    /// 头像的渐变色，按名字固定挑一组
    static func avatar(for name: String) -> [Color] {
        let sets: [[Color]] = [
            [Color(red: 0.98, green: 0.55, blue: 0.47), Color(red: 0.93, green: 0.33, blue: 0.40)],
            [Color(red: 0.99, green: 0.74, blue: 0.36), Color(red: 0.96, green: 0.53, blue: 0.20)],
            [Color(red: 0.45, green: 0.85, blue: 0.55), Color(red: 0.20, green: 0.68, blue: 0.42)],
            [Color(red: 0.40, green: 0.78, blue: 0.98), Color(red: 0.16, green: 0.52, blue: 0.93)],
            [Color(red: 0.72, green: 0.58, blue: 0.98), Color(red: 0.50, green: 0.36, blue: 0.90)],
            [Color(red: 0.98, green: 0.56, blue: 0.80), Color(red: 0.88, green: 0.32, blue: 0.62)],
            [Color(red: 0.66, green: 0.70, blue: 0.78), Color(red: 0.48, green: 0.52, blue: 0.60)],
        ]
        // 不能用 hashValue：每次启动都会变
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % sets.count
        return sets[index]
    }
}

// MARK: - 头像

struct AvatarView: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: Palette.avatar(for: name), startPoint: .top, endPoint: .bottom),
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 时间

enum ChatTime {
    /// 侧边栏：今天显示时间，昨天显示"昨天"，一周内显示星期，再早显示日期
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// 聊天里的时间分隔，例如"今天 15:42"
    static func separator(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.month().day())) \(time)"
    }
}
