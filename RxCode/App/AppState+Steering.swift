import Foundation
import RxCodeChatKit
import RxCodeCore
import SwiftUI

extension AppState {
    /// Deliver `text` into the turn that is already running for `window`.
    ///
    /// Steering is how a second message reaches an agent mid-turn without
    /// throwing away what it is doing. Claude Code takes another `user` frame
    /// on the stdin it already holds open; Codex has `turn/steer`. The
    /// alternative — cancel the turn and start a new one — loses whatever the
    /// agent had in flight and reads to the user as an interruption, so it is
    /// now the fallback rather than the default.
    ///
    /// Returns `false` when the turn could not take the input, which leaves the
    /// message undelivered and the caller owing the user either a queue entry
    /// or an interrupt-and-resend.
    ///
    /// Attachments are not steered. Both transports can carry them in principle,
    /// but the encoding differs per provider and an attachment silently dropped
    /// mid-turn is worse than one that waits — so a message carrying any is
    /// declined here and takes the fallback path intact.
    func steerActiveStream(text: String, attachments: [Attachment], in window: WindowState) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, attachments.isEmpty else { return false }

        let state = streamState(in: window)
        guard state.isStreaming, let streamId = state.activeStreamId else { return false }

        let provider = effectiveModelSelection(in: window).provider
        guard await backend(for: provider).steer(streamId: streamId, prompt: prompt) else {
            return false
        }

        // The agent accepted it, so the transcript has to show it — the steered
        // message never passes through `sendPrompt`, which is what normally
        // appends the user bubble. `needsNewMessage` makes the agent's next
        // delta open a fresh bubble instead of extending the one it was
        // mid-way through writing before the steer landed.
        let key = queueKey(for: window)
        updateState(key) { state in
            state.messages.append(ChatMessage(role: .user, content: text))
            state.needsNewMessage = true
        }
        await saveCurrentSession(in: window)
        return true
    }

    /// Whether a "steer now" action makes sense for this window's session.
    ///
    /// Provider-level, not turn-level: it answers whether the transport can
    /// reach a running turn at all, which is what the queue UI needs in order
    /// to decide whether to offer the action. Whether *this* turn still accepts
    /// input is only knowable when the write happens, so the action can still
    /// come back empty-handed — and leaves the message queued when it does.
    func canSteer(in window: WindowState) -> Bool {
        backend(for: effectiveModelSelection(in: window).provider).supportsSteering
    }

    /// The user picked "steer now" on a queued message: hand it to the running
    /// turn and drop it from the queue.
    ///
    /// Queueing is the default for a message sent mid-turn — it waits for the
    /// turn to end, which is what most follow-ups want. This is the opt-out for
    /// the ones that don't: the agent folds the message into what it is already
    /// doing, with no cancellation and no new turn.
    ///
    /// Returns `false` when the turn wouldn't take it, which leaves the message
    /// in the queue — still the user's, still delivered when the turn ends. The
    /// one exception is a turn that finished underneath the click: there is
    /// nothing left to interrupt, so the message is simply sent now.
    @discardableResult
    func steerQueuedMessage(id: UUID, in window: WindowState) async -> Bool {
        guard let target = window.messageQueue.first(where: { $0.id == id }) else { return false }

        if await steerActiveStream(text: target.text, attachments: target.attachments, in: window) {
            withAnimation(.easeOut(duration: 0.15)) {
                removeQueuedMessage(id: id, in: window)
            }
            return true
        }

        guard isStreaming(in: window) else {
            await sendQueuedNow(id: id, in: window)
            return true
        }
        return false
    }

    /// "Steer all as one": joins every queued message into a single steer.
    ///
    /// Same contract as `steerQueuedMessage(id:in:)` — on `false` the queue is
    /// untouched and still flushes when the turn ends.
    @discardableResult
    func steerAllQueuedAsOne(in window: WindowState) async -> Bool {
        guard !window.messageQueue.isEmpty else { return false }
        let snapshot = window.messageQueue
        let combined = snapshot
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        guard await steerActiveStream(
            text: combined,
            attachments: snapshot.flatMap(\.attachments),
            in: window
        ) else {
            guard isStreaming(in: window) else {
                await sendAllQueuedAsOne(in: window)
                return true
            }
            return false
        }

        let key = queueKey(for: window)
        withAnimation(.easeOut(duration: 0.15)) {
            window.messageQueue.removeAll()
        }
        window.draftQueues.removeValue(forKey: key)
        threadStore.clearQueue(sessionKey: key)
        broadcastMobileSessionStatus(sessionID: key)
        return true
    }
}
