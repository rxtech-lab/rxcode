import CryptoKit
import Foundation
import RxCodeCore

/// The complete task history stays inside the encrypted payload, including reviews.
public struct CloudTaskActivity: Codable, Sendable, Equatable {
    public let projectID: String
    public let taskID: String
    public let updatedAt: Date
    public let sourceProjectID: UUID
    public let sourceTaskID: UUID
    public let senderPublicKey: String
    public let sessionID: String?
    public let runs: [TaskRunTurn]
    public let connections: [MobileTaskLinkedSession]
    public let attentionReason: String?

    public init(projectID: String, taskID: String, updatedAt: Date, sourceProjectID: UUID,
                sourceTaskID: UUID, senderPublicKey: String, sessionID: String?, runs: [TaskRunTurn],
                connections: [MobileTaskLinkedSession], attentionReason: String?) {
        self.projectID = projectID
        self.taskID = taskID
        self.updatedAt = updatedAt
        self.sourceProjectID = sourceProjectID
        self.sourceTaskID = sourceTaskID
        self.senderPublicKey = senderPublicKey
        self.sessionID = sessionID
        self.runs = runs
        self.connections = connections
        self.attentionReason = attentionReason
    }
}

/// Only this opaque envelope crosses the cloud API. Public keys identify recipients;
/// the keys themselves are trusted through pairing, never through the cloud response.
public struct EncryptedTaskActivity: Codable, Sendable, Equatable {
    public struct Box: Codable, Sendable, Equatable {
        public let nonce: Data
        public let ciphertext: Data
    }
    public let version: Int
    public let sender: String
    public let recipients: [String: Box]

    public enum Failure: Error { case unsupportedVersion, untrustedSender, wrongRecipient, invalidContext, tooLarge }

    public static func seal(_ activity: CloudTaskActivity, identity: DeviceIdentity,
                            recipientKeys: [String]) throws -> Self {
        guard activity.senderPublicKey == identity.publicKeyHex else { throw Failure.invalidContext }
        guard Set(recipientKeys + [identity.publicKeyHex]).count <= 32 else { throw Failure.tooLarge }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(activity)
        var boxes: [String: Box] = [:]
        for hex in Set(recipientKeys + [identity.publicKeyHex]) {
            let key = try publicKey(hex)
            let sealed = try SessionCrypto.seal(plaintext: plaintext, sender: identity.privateKey,
                recipient: key, salt: context(projectID: activity.projectID, taskID: activity.taskID))
            boxes[hex] = Box(nonce: sealed.nonce, ciphertext: sealed.ciphertext)
        }
        let result = Self(version: 1, sender: identity.publicKeyHex, recipients: boxes)
        guard try encoder.encode(result).count <= 3_000_000 else { throw Failure.tooLarge }
        return result
    }

    public func open(identity: DeviceIdentity, trustedSenders: Set<String>, projectID: String,
                     taskID: String) throws -> CloudTaskActivity {
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard trustedSenders.contains(sender) else { throw Failure.untrustedSender }
        guard let box = recipients[identity.publicKeyHex] else { throw Failure.wrongRecipient }
        let plaintext = try SessionCrypto.open(ciphertext: box.ciphertext, nonce: box.nonce,
            recipient: identity.privateKey, sender: Self.publicKey(sender),
            salt: Self.context(projectID: projectID, taskID: taskID))
        let activity = try JSONDecoder().decode(CloudTaskActivity.self, from: plaintext)
        guard activity.projectID == projectID, activity.taskID == taskID, activity.senderPublicKey == sender else { throw Failure.invalidContext }
        return activity
    }

    public static func fingerprint(_ activity: CloudTaskActivity, recipients: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(activity) + Data(Set(recipients).sorted().joined(separator: ",").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func publicKey(_ hex: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let data = Data(hexString: hex), data.count == 32 else { throw SessionCrypto.CryptoError.invalidPubkeyLength }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    private static func context(projectID: String, taskID: String) -> Data {
        Data("rxcode-cloud-task/v1|\(projectID)|\(taskID)".utf8)
    }
}

public struct CloudTaskActivityRecord: Codable, Sendable {
    public let taskId: String
    public let envelope: EncryptedTaskActivity
}

public struct CloudTaskActivityPage: Codable, Sendable {
    public let items: [CloudTaskActivityRecord]
    public let nextCursor: String?
}
