import UserNotifications
import CryptoKit
import RxCodeSync

/// Notification Service Extension: decrypts the `enc` payload that the desktop
/// sealed for this device and rewrites the visible alert before iOS displays
/// the banner. The shared Keychain access group makes the device's long-term
/// Curve25519 private key available to this extension.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let attempt = bestAttempt else {
            contentHandler(request.content); return
        }

        guard let encB64 = request.content.userInfo["enc"] as? String,
              let raw = Data(base64Encoded: encB64),
              let envelope = try? JSONDecoder().decode(EncryptedAlert.self, from: raw),
              let identity = try? DeviceIdentity.loadOrCreate(
                accessGroup: "$(AppIdentifierPrefix)com.idealapp.RxCode.Mobile.shared"
              ),
              let senderRaw = Data(hexString: envelope.from),
              let senderKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw),
              let plaintext = try? APNsCrypto.open(envelope: envelope, recipient: identity.privateKey, sender: senderKey)
        else {
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
        contentHandler(attempt)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let attempt = bestAttempt {
            handler(attempt)
        }
    }
}
