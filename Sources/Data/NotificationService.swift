/// 文件说明：NotificationService，封装本地通知的权限请求、发送与深度链接解析。
/// 使用 Communication Notifications（INSendMessageIntent）实现聊天风格通知，
/// 服务器图标作为发送者头像显示在通知左侧。
import UserNotifications
import Intents

/// NotificationService：
/// 负责在用户不在聊天页面或 App 在后台时，通过本地通知提醒用户 AI 需要决策。
/// 通知携带 serverID，点击后可跳转到对应聊天页。
@Observable
final class NotificationService: NSObject, @unchecked Sendable {
    /// 用户点击通知后待导航的目标。
    var pendingNavigation: NotificationNavigation?

    /// 通知导航目标。
    struct NotificationNavigation: Equatable {
        let serverID: UUID
    }

    private static let categoryApproval = "AI_APPROVAL"
    private static let categoryReply = "AI_REPLY"
    private static let actionApproveOnce = "APPROVE_ONCE"
    private static let actionDeny = "DENY"

    /// 本地审批通知动作回调（App 存活时连四态审批）。
    @ObservationIgnored
    var onNotificationApproval: (@MainActor (UUID, CommandApproval) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 注册通知类别
        let approve = UNNotificationAction(
            identifier: Self.actionApproveOnce,
            title: String(localized: "Approve Once", bundle: LanguageSettings.currentBundle),
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.actionDeny,
            title: String(localized: "Deny", bundle: LanguageSettings.currentBundle),
            options: [.destructive]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: Self.categoryApproval,
            actions: [approve, deny],
            intentIdentifiers: [NSStringFromClass(INSendMessageIntent.self)]
        )
        let replyCategory = UNNotificationCategory(
            identifier: Self.categoryReply,
            actions: [],
            intentIdentifiers: [NSStringFromClass(INSendMessageIntent.self)]
        )
        center.setNotificationCategories([approvalCategory, replyCategory])
    }

    /// 请求通知权限。
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Notification] Authorization error: \(error)")
            }
            print("[Notification] Authorization granted: \(granted)")
        }
    }

    /// 发送"AI 需要你审批操作"的本地通知。
    func sendApprovalNotification(
        toolName: String,
        serverName: String,
        serverIconData: Data?,
        serverID: UUID
    ) {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "Approve operation: \(toolName)", bundle: LanguageSettings.currentBundle)
        content.sound = .default
        content.categoryIdentifier = Self.categoryApproval
        content.threadIdentifier = serverID.uuidString
        content.userInfo = ["serverID": serverID.uuidString]

        let finalContent = Self.applyCommunicationStyle(
            to: content,
            serverName: serverName,
            serverIconData: serverIconData,
            serverID: serverID
        )

        let request = UNNotificationRequest(
            identifier: "approval-\(serverID.uuidString)",
            content: finalContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 发送 AI 回复通知（聊天风格：服务器名为发送者，头像在左侧）。
    func sendReplyNotification(
        serverName: String,
        serverIconData: Data?,
        messagePreview: String,
        serverID: UUID
    ) {
        let content = UNMutableNotificationContent()
        content.body = messagePreview
        content.sound = .default
        content.categoryIdentifier = Self.categoryReply
        content.threadIdentifier = serverID.uuidString
        content.userInfo = ["serverID": serverID.uuidString]

        let finalContent = Self.applyCommunicationStyle(
            to: content,
            serverName: serverName,
            serverIconData: serverIconData,
            serverID: serverID
        )

        let request = UNNotificationRequest(
            identifier: "reply-\(serverID.uuidString)-\(UUID().uuidString.prefix(8))",
            content: finalContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Communication Style

    /// 使用 INSendMessageIntent 将通知转为通信风格，头像显示在左侧。
    private static func applyCommunicationStyle(
        to content: UNMutableNotificationContent,
        serverName: String,
        serverIconData: Data?,
        serverID: UUID
    ) -> UNNotificationContent {
        // 先设置 title 作为兜底，即使通信风格未生效也能显示服务器名
        content.title = serverName

        // 通过 imageData 创建 INImage，本地通知无需写入文件
        let avatar: INImage? = serverIconData.map { INImage(imageData: $0) }

        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: serverID.uuidString, type: .unknown),
            nameComponents: nil,
            displayName: serverName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: serverID.uuidString
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: serverID.uuidString,
            serviceName: nil,
            sender: senderPerson,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            let updated = try content.updating(from: intent)
            return updated
        } catch {
            print("[Notification] Failed to apply communication style: \(error)")
            return content
        }
    }

    /// 处理通知动作：approve/deny 且仍有待审批 → 回调；否则深链。
    func handleAction(actionIdentifier: String, userInfo: [AnyHashable: Any],
                      hasPendingApproval: (UUID) -> Bool) async {
        guard let nav = Self.parseNavigation(from: userInfo) else { return }
        if (actionIdentifier == Self.actionApproveOnce || actionIdentifier == Self.actionDeny),
           hasPendingApproval(nav.serverID) {
            let outcome: CommandApproval = actionIdentifier == Self.actionApproveOnce ? .approvedOnce : .denied
            await MainActor.run { self.onNotificationApproval?(nav.serverID, outcome) }
        } else {
            await MainActor.run { self.pendingNavigation = nav }
        }
    }

    /// 解析通知的 userInfo 为导航目标。
    static func parseNavigation(from userInfo: [AnyHashable: Any]) -> NotificationNavigation? {
        guard let serverStr = userInfo["serverID"] as? String,
              let serverID = UUID(uuidString: serverStr) else {
            return nil
        }
        return NotificationNavigation(serverID: serverID)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// App 在前台时也显示通知横幅（用户可能在其他页面）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 用户点击通知或选择动作后转交 handleAction。
    /// `hasPendingApproval` 的真实判定由装配方（DI）经 onNotificationApproval 注入；
    /// 在 I7 接线前默认 false，动作降级为深链导航，保持既有行为。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let hasPending = onNotificationApproval != nil
        await handleAction(
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo,
            hasPendingApproval: { _ in hasPending }
        )
    }
}
