import Foundation
import RxAgentVoice

/// Speech requests use the current realtime transport, never a competing local speaker.
@MainActor
final class PetRealtimeVoiceNotifications {
    final class Receipt { var acknowledged = false }
    private var sender: (@Sendable (String) async throws -> Void)?
    private(set) var isReady = false
    private(set) var isResponding = false
    private(set) var completedReplies = 0
    private var onReply: (@MainActor () -> Void)?
    var canSend: Bool { isReady && sender != nil && !isResponding }

    func bind(_ sender: @escaping @Sendable (String) async throws -> Void) { self.sender = sender }
    func connected() { isReady = true }
    func responseStarted() { isResponding = true }
    func responseFinished() {
        isResponding = false
        completedReplies += 1
        let completed = onReply
        onReply = nil
        completed?()
    }
    func disconnected() { isReady = false; sender = nil; onReply = nil }

    func send(_ text: String, onReply: (@MainActor () -> Void)? = nil) async throws {
        guard isReady, !isResponding, let sender else { throw VoiceError.invalidState }
        isResponding = true
        self.onReply = onReply
        do { try await sender(text) }
        catch { isResponding = false; self.onReply = nil; throw error }
    }
}
