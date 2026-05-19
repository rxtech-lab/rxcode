import UIKit
import UserNotifications
import CryptoKit
import RxCodeSync
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
        let requestID = notification.request.identifier
        logger.info("[APNs] willPresent request=\(requestID, privacy: .public) title=\(content.title, privacy: .public) body=\(content.body, privacy: .public) category=\(content.categoryIdentifier, privacy: .public) keys=\(content.userInfo.keys.map { "\($0)" }.sorted().joined(separator: ","), privacy: .public) aps=\(Self.apnsSummary(content.userInfo), privacy: .public)")
        if content.userInfo["rxcodeForegroundDecrypted"] as? Bool == true {
            logger.info("[APNs] willPresent decrypted foreground replacement request=\(requestID, privacy: .public)")
            return [.banner, .sound, .list]
        }
        if let replacement = decryptedForegroundNotification(from: content, requestID: requestID) {
            do {
                let replacementID = "rxcode-decrypted-\(requestID)"
                try await center.add(UNNotificationRequest(identifier: replacementID, content: replacement, trigger: nil))
                logger.info("[APNs] foreground encrypted notification replaced request=\(requestID, privacy: .public) replacement=\(replacementID, privacy: .public)")
                return []
            } catch {
                logger.error("[APNs] foreground decrypted replacement scheduling failed request=\(requestID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return [.banner, .sound, .list]
    }

    private func decryptedForegroundNotification(from content: UNNotificationContent,
                                                 requestID: String) -> UNMutableNotificationContent? {
        guard let encB64 = content.userInfo["enc"] as? String else {
            logger.info("[APNs] foreground notification has no enc payload request=\(requestID, privacy: .public)")
            return nil
        }
        guard let raw = Data(base64Encoded: encB64) else {
            logger.error("[APNs] foreground enc payload is not valid base64 request=\(requestID, privacy: .public) length=\(encB64.count, privacy: .public)")
            return nil
        }
        let envelope: EncryptedAlert
        do {
            envelope = try JSONDecoder().decode(EncryptedAlert.self, from: raw)
        } catch {
            logger.error("[APNs] foreground encrypted alert decode failed request=\(requestID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let accessGroup = DeviceIdentity.resolveAccessGroup(suffix: "app.rxlab.rxcodemobile.shared")
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.loadOrCreate(accessGroup: accessGroup)
            logger.info("[APNs] foreground identity loaded accessGroup=\(accessGroup, privacy: .public) publicKey=\(String(identity.publicKeyHex.prefix(12)), privacy: .public) sender=\(String(envelope.from.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[APNs] foreground identity load failed accessGroup=\(accessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let senderRaw = Data(rxcodeHexString: envelope.from) else {
            logger.error("[APNs] foreground sender public key is not hex sender=\(String(envelope.from.prefix(12)), privacy: .public)")
            return nil
        }
        let senderKey: Curve25519.KeyAgreement.PublicKey
        do {
            senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw)
        } catch {
            logger.error("[APNs] foreground sender public key parse failed sender=\(String(envelope.from.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let plaintext: AlertPlaintext
        do {
            plaintext = try APNsCrypto.open(envelope: envelope, recipient: identity.privateKey, sender: senderKey)
        } catch {
            logger.error("[APNs] foreground decrypt failed request=\(requestID, privacy: .public) sender=\(String(envelope.from.prefix(12)), privacy: .public) identity=\(String(identity.publicKeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let replacement = content.mutableCopy() as? UNMutableNotificationContent else {
            logger.error("[APNs] foreground unable to copy notification content request=\(requestID, privacy: .public)")
            return nil
        }
        replacement.title = plaintext.title
        replacement.body = plaintext.body
        var userInfo = replacement.userInfo
        userInfo["rxcodeForegroundDecrypted"] = true
        if let sessionID = plaintext.sessionID { userInfo["sessionId"] = sessionID }
        if let projectID = plaintext.projectID { userInfo["projectId"] = projectID.uuidString }
        if let kind = plaintext.kind { userInfo["kind"] = kind }
        replacement.userInfo = userInfo
        logger.info("[APNs] foreground decrypted notification request=\(requestID, privacy: .public) kind=\(plaintext.kind ?? "<nil>", privacy: .public) sessionID=\(plaintext.sessionID ?? "<nil>", privacy: .public)")
        return replacement
    }

    private static func apnsSummary(_ userInfo: [AnyHashable: Any]) -> String {
        guard let aps = userInfo["aps"] as? [String: Any] else { return "<missing>" }
        let mutableContent = aps["mutable-content"].map { "\($0)" } ?? "<nil>"
        let contentAvailable = aps["content-available"].map { "\($0)" } ?? "<nil>"
        let alertSummary: String
        if let alert = aps["alert"] as? [String: Any] {
            let title = alert["title"].map { "\($0)" } ?? "<nil>"
            let body = alert["body"].map { "\($0)" } ?? "<nil>"
            alertSummary = "title=\(title),body=\(body)"
        } else {
            alertSummary = "\(aps["alert"] ?? "<nil>")"
        }
        return "mutable-content=\(mutableContent),content-available=\(contentAvailable),alert={\(alertSummary)}"
    }
}

private extension Data {
    init?(rxcodeHexString: String) {
        let chars = Array(rxcodeHexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index..<index + 2]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
