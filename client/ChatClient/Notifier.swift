import AppKit
import UserNotifications

/// 系统通知：新消息、来电。点通知会打开对应的会话
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// 点了某个会话的通知
    var onOpenConversation: ((Int64) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    /// 登录后调用一次，第一次会弹出系统的授权询问
    func requestAuthorization() {
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func notifyMessage(conversationId: Int64, from sender: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = body
        content.sound = .default
        content.threadIdentifier = "conversation-\(conversationId)"
        content.userInfo = ["conversation_id": conversationId]
        post(content)
    }

    func notifyIncomingCall(conversationId: Int64, from caller: String) {
        let content = UNMutableNotificationContent()
        content.title = caller
        content.body = "邀请你语音通话"
        content.threadIdentifier = "call"
        content.userInfo = ["conversation_id": conversationId]
        post(content, id: "incoming-call")
    }

    func removeIncomingCall() {
        center.removeDeliveredNotifications(withIdentifiers: ["incoming-call"])
    }

    /// 会话打开后，把它在通知中心里的通知清掉
    func clear(conversationId: Int64) {
        let thread = "conversation-\(conversationId)"
        Task {
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == thread }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
    }

    private func post(_ content: UNMutableNotificationContent, id: String = UUID().uuidString) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也显示横幅（只有不在看那个会话时才会发通知）
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let value = response.notification.request.content.userInfo["conversation_id"] as? NSNumber
        guard let conversationId = value?.int64Value else { return }
        await MainActor.run {
            NSApp.activate()
            onOpenConversation?(conversationId)
        }
    }
}
