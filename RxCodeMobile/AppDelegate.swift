import UIKit
import UserNotifications
import os.log

/// Bridges UIKit's APNs registration into `MobileAppState`. The state object
/// forwards the device token to the paired desktop over the encrypted relay.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var mobileState: MobileAppState?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "AppDelegate")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        logger.info("[APNs] notification delegate installed")
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            self.logger.info("[APNs] authorization granted=\(granted, privacy: .public)")
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                self.logger.warning("[APNs] authorization denied; remote notification registration skipped")
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
#if DEBUG
        let environment = "sandbox"
#else
        let environment = "production"
#endif
        logger.info("[APNs] registered tokenPrefix=\(String(tokenHex.prefix(12)), privacy: .public) environment=\(environment, privacy: .public)")
        mobileState?.reportAPNsToken(hex: tokenHex, environment: environment)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.error("[APNs] registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        logger.info("[APNs] willPresent title=\(content.title, privacy: .public) body=\(content.body, privacy: .public) category=\(content.categoryIdentifier, privacy: .public) keys=\(content.userInfo.keys.map { "\($0)" }.sorted().joined(separator: ","), privacy: .public)")
        return [.banner, .sound, .list]
    }
}
