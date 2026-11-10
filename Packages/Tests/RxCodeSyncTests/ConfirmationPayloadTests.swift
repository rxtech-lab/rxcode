import Foundation
import Testing
@testable import RxCodeSync

@Suite("Confirmation tool sync payloads")
struct ConfirmationPayloadTests {
    @Test("confirmation queue round trips through the tagged payload")
    func queueRoundTrip() throws {
        let pending = PendingConfirmationPayload(
            id: UUID().uuidString,
            sessionID: "session-1",
            projectID: UUID(),
            title: "Delete 3 files?",
            message: "This cannot be undone.",
            confirmLabel: "Delete",
            cancelLabel: "Keep",
            isDestructive: true
        )
        let data = try JSONEncoder().encode(Payload.confirmationQueue(ConfirmationQueuePayload(confirmations: [pending])))
        #expect(String(decoding: data, as: UTF8.self).contains(#""type":"confirmation_queue""#))
        guard case .confirmationQueue(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected confirmation_queue")
            return
        }
        #expect(decoded.confirmations == [pending])
    }

    @Test("confirmation decision round trips through the tagged payload")
    func decisionRoundTrip() throws {
        let data = try JSONEncoder().encode(Payload.confirmationDecision(ConfirmationDecisionPayload(id: "abc", confirmed: false)))
        guard case .confirmationDecision(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected confirmation_decision")
            return
        }
        #expect(decoded.id == "abc")
        #expect(decoded.confirmed == false)
    }
}
