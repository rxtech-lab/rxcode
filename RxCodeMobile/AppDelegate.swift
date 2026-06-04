import UIKit
import UserNotifications
import CryptoKit
import RxCodeSync
import os.log
#if canImport(SDWebImageSVGCoder)
import SDWebImage
import SDWebImageSVGCoder
#endif

/// Bridges UIKit's APNs registration into `MobileAppState`. The state object
/// forwards the device token to the paired desktop over the encrypted relay.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var mobileState: MobileAppState? {
        didSet {
            guard let target = pendingNotificationDeepLink, let state = mobileState else { return }
            pendingNotificationDeepLink = nil
            logger.info("[APNs] flushing buffered notification deep link sessionID=\(target.sessionID, privacy: .public)")
            state.openThreadFromNotification(sessionID: target.sessionID, projectID: target.projectID)
        }
    }
    /// Buffers a notification tap that arrives before `mobileState` is wired up
    /// (cold launch). Flushed by the `mobileState` `didSet` above.
    private var pendingNotificationDeepLink: (sessionID: String, projectID: UUID?)?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "AppDelegate")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseBootstrap.configure()
        #if canImport(SDWebImageSVGCoder)
        // ACP registry icons are monochrome SVGs; register the coder so
        // SDWebImage can decode them for `MobileACPIconView`.
        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
        #endif
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
        let environment = MobileAppState.currentAPNsEnvironment
        logger.info("[APNs] registered tokenPrefix=\(String(tokenHex.prefix(12)), privacy: .public) environment=\(environment, privacy: .public)")
        mobileState?.reportAPNsToken(hex: tokenHex, environment: environment)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.error("[APNs] registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Handles a silent background push carrying a fresh home-screen widget
    /// snapshot. The desktop sends these (`push_type=background`) whenever the
    /// ongoing-job count or agent usage changes. The snapshot is E2E-encrypted
    /// to this device under `encWidget` and decrypted here before it reaches
    /// the widget store.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let snapshot = decryptWidgetSnapshot(from: userInfo, context: "background-push") else {
            return .noData
        }
        // Merge into the existing snapshot so a job-count-only push doesn't
        // wipe the usage figures (and vice versa).
        var stored = RxCodeWidgetStore.load()
        if let jobs = snapshot.jobs { stored.jobCount = jobs }
        if let cc = snapshot.cc { stored.ccUsagePercent = cc }
        if let ccWeekly = snapshot.ccWeekly { stored.ccWeeklyUsagePercent = ccWeekly }
        if let codex = snapshot.codex { stored.codexUsagePercent = codex }
        if let codexWeekly = snapshot.codexWeekly { stored.codexWeeklyUsagePercent = codexWeekly }
        stored.updatedAt = snapshot.updatedAt
        RxCodeWidgetStore.save(stored)
        logger.info("[Widget] background push applied jobs=\(stored.jobCount, privacy: .public)")
        return .newData
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

    /// Handles a notification tap — banner, lock screen, or cold launch from a
    /// killed app. Routes the UI to the notification's thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let requestID = response.notification.request.identifier
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            logger.info("[APNs] notification action ignored request=\(requestID, privacy: .public) action=\(response.actionIdentifier, privacy: .public)")
            return
        }
        let userInfo = response.notification.request.content.userInfo
        guard let target = notificationThreadTarget(from: userInfo, requestID: requestID) else {
            logger.info("[APNs] notification tap has no thread target request=\(requestID, privacy: .public)")
            return
        }
        if let state = mobileState {
            state.openThreadFromNotification(sessionID: target.sessionID, projectID: target.projectID)
        } else {
            logger.info("[APNs] notification tap buffered (state not ready) request=\(requestID, privacy: .public)")
            pendingNotificationDeepLink = target
        }
    }

    /// Resolves the `(sessionID, projectID)` a tapped notification points to.
    /// The NSE / foreground handler usually decrypts these into `userInfo`
    /// already; if only the encrypted `enc` blob is present (NSE failed), this
    /// decrypts it as a fallback.
    private func notificationThreadTarget(from userInfo: [AnyHashable: Any],
                                          requestID: String) -> (sessionID: String, projectID: UUID?)? {
        if let sessionID = userInfo["sessionId"] as? String, !sessionID.isEmpty {
            let projectID = (userInfo["projectId"] as? String).flatMap(UUID.init)
            return (sessionID, projectID)
        }
        guard let plaintext = decryptAlertPlaintext(from: userInfo, context: requestID),
              let sessionID = plaintext.sessionID, !sessionID.isEmpty
        else { return nil }
        return (sessionID, plaintext.projectID)
    }

    private func decryptedForegroundNotification(from content: UNNotificationContent,
                                                 requestID: String) -> UNMutableNotificationContent? {
        guard let plaintext = decryptAlertPlaintext(from: content.userInfo, context: requestID) else {
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

    /// Decrypts the `enc` blob nested in an APNs payload into its
    /// `AlertPlaintext`. Shared by the foreground replacement path and the
    /// notification-tap fallback. `context` is a request identifier for logging.
    private func decryptAlertPlaintext(from userInfo: [AnyHashable: Any],
                                       context: String) -> AlertPlaintext? {
        guard let resolved = resolveEncryptedEnvelope(from: userInfo, key: "enc", context: context) else {
            return nil
        }
        do {
            return try APNsCrypto.open(envelope: resolved.envelope,
                                       recipient: resolved.recipient,
                                       sender: resolved.sender)
        } catch {
            logger.error("[APNs] decrypt failed context=\(context, privacy: .public) sender=\(String(resolved.envelope.from.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Decrypts the `encWidget` blob carried by a silent background push into a
    /// `WidgetSnapshotPayload`. The desktop seals one envelope per device, so
    /// the relay only ever forwards opaque ciphertext.
    private func decryptWidgetSnapshot(from userInfo: [AnyHashable: Any],
                                       context: String) -> WidgetSnapshotPayload? {
        guard let resolved = resolveEncryptedEnvelope(from: userInfo, key: "encWidget", context: context) else {
            return nil
        }
        do {
            return try APNsCrypto.openWidget(envelope: resolved.envelope,
                                             recipient: resolved.recipient,
                                             sender: resolved.sender)
        } catch {
            logger.error("[Widget] decrypt failed context=\(context, privacy: .public) sender=\(String(resolved.envelope.from.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Resolves the `EncryptedAlert` envelope stored under `key`, together with
    /// the local device private key and the sender's public key needed to open
    /// it. Shared by the alert and widget decryption paths. `context` is a
    /// request identifier used for logging.
    private func resolveEncryptedEnvelope(
        from userInfo: [AnyHashable: Any],
        key: String,
        context: String
    ) -> (envelope: EncryptedAlert,
          recipient: Curve25519.KeyAgreement.PrivateKey,
          sender: Curve25519.KeyAgreement.PublicKey)? {
        guard let encB64 = userInfo[key] as? String else {
            logger.info("[APNs] notification has no \(key, privacy: .public) payload context=\(context, privacy: .public)")
            return nil
        }
        guard let raw = Data(base64Encoded: encB64) else {
            logger.error("[APNs] \(key, privacy: .public) payload is not valid base64 context=\(context, privacy: .public) length=\(encB64.count, privacy: .public)")
            return nil
        }
        let envelope: EncryptedAlert
        do {
            envelope = try JSONDecoder().decode(EncryptedAlert.self, from: raw)
        } catch {
            logger.error("[APNs] encrypted envelope decode failed context=\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let accessGroup = DeviceIdentity.resolveAccessGroup(suffix: "app.rxlab.rxcodemobile.shared")
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.loadOrCreate(accessGroup: accessGroup)
        } catch {
            logger.error("[APNs] identity load failed accessGroup=\(accessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let senderRaw = Data(rxcodeHexString: envelope.from) else {
            logger.error("[APNs] sender public key is not hex sender=\(String(envelope.from.prefix(12)), privacy: .public)")
            return nil
        }
        let senderKey: Curve25519.KeyAgreement.PublicKey
        do {
            senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw)
        } catch {
            logger.error("[APNs] sender public key parse failed sender=\(String(envelope.from.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (envelope, identity.privateKey, senderKey)
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
