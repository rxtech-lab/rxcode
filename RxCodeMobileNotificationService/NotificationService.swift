import UserNotifications
import CryptoKit
import RxCodeSync
import os.log

/// Notification Service Extension: decrypts the `enc` payload that the desktop
/// sealed for this device and rewrites the visible alert before iOS displays
/// the banner. The shared Keychain access group makes the device's long-term
/// Curve25519 private key available to this extension.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "NotificationService")

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let attempt = bestAttempt else {
            logger.error("[NSE] unable to copy notification content request=\(request.identifier, privacy: .public)")
            contentHandler(request.content); return
        }

        logger.info("[NSE] received request=\(request.identifier, privacy: .public) category=\(request.content.categoryIdentifier, privacy: .public) userInfoKeys=\(request.content.userInfo.keys.map { "\($0)" }.sorted().joined(separator: ","), privacy: .public)")

        guard let encB64 = request.content.userInfo["enc"] as? String else {
            logger.error("[NSE] missing enc payload request=\(request.identifier, privacy: .public)")
            contentHandler(attempt)
            return
        }
        guard let raw = Data(base64Encoded: encB64) else {
            logger.error("[NSE] enc payload is not valid base64 request=\(request.identifier, privacy: .public) length=\(encB64.count, privacy: .public)")
            contentHandler(attempt)
            return
        }
        let envelope: EncryptedAlert
        do {
            envelope = try JSONDecoder().decode(EncryptedAlert.self, from: raw)
        } catch {
            logger.error("[NSE] encrypted alert decode failed request=\(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            contentHandler(attempt)
            return
        }
        let accessGroup = DeviceIdentity.resolveAccessGroup(
            suffix: "app.rxlab.rxcodemobile.shared"
        )
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.loadOrCreate(
                accessGroup: accessGroup
            )
            logger.info("[NSE] loaded identity accessGroup=\(accessGroup, privacy: .public) publicKey=\(String(identity.publicKeyHex.prefix(12)), privacy: .public) sender=\(String(envelope.from.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[NSE] identity load failed accessGroup=\(accessGroup, privacy: .public): \(error.localizedDescription, privacy: .public)")
            contentHandler(attempt)
            return
        }
        guard let senderRaw = Data(hexString: envelope.from) else {
            logger.error("[NSE] sender public key is not hex sender=\(String(envelope.from.prefix(12)), privacy: .public)")
            contentHandler(attempt)
            return
        }
        let senderKey: Curve25519.KeyAgreement.PublicKey
        do {
            senderKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw)
        } catch {
            logger.error("[NSE] sender public key parse failed sender=\(String(envelope.from.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            contentHandler(attempt)
            return
        }
        let plaintext: AlertPlaintext
        do {
            plaintext = try APNsCrypto.open(envelope: envelope, recipient: identity.privateKey, sender: senderKey)
        } catch {
            logger.error("[NSE] decrypt failed request=\(request.identifier, privacy: .public) sender=\(String(envelope.from.prefix(12)), privacy: .public) identity=\(String(identity.publicKeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            contentHandler(attempt)
            return
        }

        attempt.title = plaintext.title
        attempt.body = plaintext.body
        var userInfo = attempt.userInfo
        if let sessionID = plaintext.sessionID { userInfo["sessionId"] = sessionID }
        if let projectID = plaintext.projectID { userInfo["projectId"] = projectID.uuidString }
        if let kind = plaintext.kind { userInfo["kind"] = kind }
        attempt.userInfo = userInfo
        logger.info("[NSE] decrypted notification request=\(request.identifier, privacy: .public) kind=\(plaintext.kind ?? "<nil>", privacy: .public) sessionID=\(plaintext.sessionID ?? "<nil>", privacy: .public)")
        contentHandler(attempt)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let attempt = bestAttempt {
            logger.error("[NSE] service extension time will expire; returning best attempt title=\(attempt.title, privacy: .public)")
            handler(attempt)
        }
    }
}
