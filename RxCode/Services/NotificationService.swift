import AppKit
import UserNotifications
import os.log

/// Thin wrapper around UNUserNotificationCenter for "response complete" banners.
/// Notifications carry the project ID in userInfo so taps can route back to the
/// correct project window.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "Notification")
    private var didRequestAuthorization = false

    /// Invoked on the main actor when the user clicks a notification.
    /// Parameters: projectId, sessionId
    var onNotificationTapped: ((UUID, String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization granted=\(granted)")
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    /// Post a "permission needed" notification when the CLI queues a tool approval.
    /// Silently no-ops if the user hasn't granted notification permission.
    func postPermissionNeeded(toolName: String, projectName: String?, projectId: UUID?, sessionId: String?) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        let titleFormat = NSLocalizedString(
            "Permission needed%@",
            comment: "Notification title when Claude queues a tool approval. %@ is replaced with \" — <project name>\" or empty string."
        )
        let projectSuffix: String = projectName.map { " — \($0)" } ?? ""
        content.title = String(format: titleFormat, projectSuffix)
        let bodyFormat = NSLocalizedString(
            "Approve to run %@",
            comment: "Notification body when Claude queues a tool approval. %@ is the tool name."
        )
        content.body = String(format: bodyFormat, toolName)
        content.sound = .default
        var userInfo: [String: Any] = [:]
        if let projectId { userInfo["projectId"] = projectId.uuidString }
        if let sessionId { userInfo["sessionId"] = sessionId }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post permission notification: \(error.localizedDescription)")
        }
    }

    /// Post a "question needed" notification when the CLI invokes AskUserQuestion.
    /// Silently no-ops if the user hasn't granted notification permission.
    func postQuestionNeeded(projectName: String?, projectId: UUID?, sessionId: String?) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        let titleFormat = NSLocalizedString(
            "Assistant has a question%@",
            comment: "Notification title when Claude invokes AskUserQuestion. %@ is replaced with \" — <project name>\" or empty string."
        )
        let projectSuffix: String = projectName.map { " — \($0)" } ?? ""
        content.title = String(format: titleFormat, projectSuffix)
        content.body = NSLocalizedString(
            "Tap to answer",
            comment: "Notification body when Claude invokes AskUserQuestion."
        )
        content.sound = .default
        var userInfo: [String: Any] = [:]
        if let projectId { userInfo["projectId"] = projectId.uuidString }
        if let sessionId { userInfo["sessionId"] = sessionId }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post question notification: \(error.localizedDescription)")
        }
    }

    /// Post a "MCP server disconnected" notification when a periodic/manual probe
    /// transitions a server from connected to failed. Silently no-ops if the user
    /// hasn't granted notification permission.
    func postMCPDisconnected(name: String, error: String?) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString(
            "MCP server disconnected",
            comment: "Notification title when an MCP server transitions from connected to failed."
        )
        let bodyFormat = NSLocalizedString(
            "%@ — %@",
            comment: "Notification body for MCP disconnect: server name and error detail."
        )
        let detail = (error?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? NSLocalizedString("connection lost", comment: "Fallback MCP disconnect detail when no error message is available.")
        content.body = String(format: bodyFormat, name, detail)
        content.sound = .default
        content.userInfo = ["mcpServerName": name]

        let request = UNNotificationRequest(
            identifier: "mcp-disconnect-\(name)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post MCP disconnect notification: \(error.localizedDescription)")
        }
    }

    /// Post a "response complete" notification. Silently no-ops if unauthorized.
    func postResponseComplete(title: String, body: String, projectId: UUID, sessionId: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty
            ? NSLocalizedString("Response complete", comment: "Notification body when Claude finishes a response")
            : body
        content.sound = .default
        content.userInfo = ["projectId": projectId.uuidString, "sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let projectIdString = userInfo["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdString),
              let sessionId = userInfo["sessionId"] as? String else { return }

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.onNotificationTapped?(projectId, sessionId)
        }
    }
}
