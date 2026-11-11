import CryptoKit
import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Encrypted cloud task history")
struct CloudTaskActivityTests {
    private func activity(_ identity: DeviceIdentity) -> CloudTaskActivity {
        CloudTaskActivity(projectID: "project", taskID: "task", updatedAt: Date(timeIntervalSince1970: 123),
            sourceProjectID: UUID(), sourceTaskID: UUID(), senderPublicKey: identity.publicKeyHex, sessionID: "chat",
            runs: [TaskRunTurn(id: 0, prompt: "Private initial prompt", response: "Private agent response", didError: false),
                   TaskRunTurn(id: 1, prompt: "Private follow-up", response: "Private follow-up answer", didError: false)],
            connections: [MobileTaskLinkedSession(id: "review", title: "Check", kind: .review, feedback: "Private review feedback")],
            attentionReason: "Private rejection reason")
    }

    @Test func onlyPairedRecipientsCanReadHistory() throws {
        let desktop = DeviceIdentity(privateKey: .init())
        let phone = DeviceIdentity(privateKey: .init())
        let outsider = DeviceIdentity(privateKey: .init())
        let source = activity(desktop)
        let sealed = try EncryptedTaskActivity.seal(source, identity: desktop, recipientKeys: [phone.publicKeyHex])
        let encoded = try JSONEncoder().encode(sealed)
        let json = String(decoding: encoded, as: UTF8.self)
        for secret in ["Private initial prompt", "Private agent response", "Private follow-up", "Private review feedback", "Private rejection reason"] {
            #expect(!json.contains(secret))
        }
        let stored = try JSONDecoder().decode(EncryptedTaskActivity.self, from: encoded)
        #expect(try stored.open(identity: phone, trustedSenders: [desktop.publicKeyHex], projectID: "project", taskID: "task") == source)
        #expect(try stored.open(identity: desktop, trustedSenders: [desktop.publicKeyHex], projectID: "project", taskID: "task") == source)
        #expect(throws: (any Error).self) {
            try stored.open(identity: outsider, trustedSenders: [desktop.publicKeyHex], projectID: "project", taskID: "task")
        }
        #expect(throws: (any Error).self) {
            try stored.open(identity: phone, trustedSenders: [], projectID: "project", taskID: "task")
        }
    }

    @Test func ciphertextCannotBeMovedToAnotherTaskOrTamperedWith() throws {
        let desktop = DeviceIdentity(privateKey: .init()), phone = DeviceIdentity(privateKey: .init())
        let sealed = try EncryptedTaskActivity.seal(activity(desktop), identity: desktop, recipientKeys: [phone.publicKeyHex])
        for context in [("other-project", "task"), ("project", "other-task")] {
            #expect(throws: (any Error).self) {
                try sealed.open(identity: phone, trustedSenders: [desktop.publicKeyHex], projectID: context.0, taskID: context.1)
            }
        }
        var boxes = sealed.recipients
        let box = boxes[phone.publicKeyHex]!
        var damaged = box.ciphertext
        damaged[damaged.startIndex] ^= 1
        boxes[phone.publicKeyHex] = .init(nonce: box.nonce, ciphertext: damaged)
        let tampered = EncryptedTaskActivity(version: 1, sender: sealed.sender, recipients: boxes)
        #expect(throws: (any Error).self) {
            try tampered.open(identity: phone, trustedSenders: [desktop.publicKeyHex], projectID: "project", taskID: "task")
        }
    }

    @Test func pairingChangesRequireHistoryToBeReencrypted() throws {
        let identity = DeviceIdentity(privateKey: .init())
        let source = activity(identity)
        let first = try EncryptedTaskActivity.fingerprint(source, recipients: ["a", "b"])
        #expect(first == (try EncryptedTaskActivity.fingerprint(source, recipients: ["b", "a", "a"])))
        #expect(first != (try EncryptedTaskActivity.fingerprint(source, recipients: ["a"])))
    }
}
