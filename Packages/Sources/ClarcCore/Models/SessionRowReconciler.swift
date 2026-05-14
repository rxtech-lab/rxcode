import Foundation

/// Pure-function decision logic for reconciling sidebar `ChatSession.Summary` rows
/// against `system` events arriving from the Claude CLI.
///
/// Used by `AppState.processStream` when a system event carries a `session_id`
/// that doesn't match the pending placeholder branch. Splitting this out of the
/// view-model lets us cover the mid-stream-sid-change cases with unit tests.
public enum SessionRowReconciler {

    public enum Action: Equatable, Sendable {
        /// Nothing to do — a row already exists for this sid, or we don't have
        /// enough context to safely create one.
        case noop
        /// Rename an existing row's id from `from` to `to`. Used when the CLI
        /// advances its `session_id` mid-stream (e.g. after a `compact_boundary`
        /// event) and the previous sid's row already represents this chat.
        case renameInPlace(from: String, to: String)
        /// Insert a brand-new row for `id` with the given title. Only emitted
        /// when there is genuinely no prior row to migrate AND the in-state
        /// messages prove the chat has real content.
        case insertNew(id: String, title: String)
    }

    /// Decide what to do when a system event with `newSid` arrives and the
    /// pending-placeholder branch has already been consumed.
    ///
    /// - Parameters:
    ///   - newSid: The `session_id` on the incoming system event.
    ///   - previousKey: The `sessionKey` value in `processStream` immediately
    ///     before the system event reassignment — i.e. what this stream's row
    ///     is currently keyed under in `allSessionSummaries`.
    ///   - existingIds: All ids currently present in `allSessionSummaries`.
    ///   - firstUserMessageContent: The first user-role message's content for
    ///     this session, if any. Used both to title a fresh row and as a signal
    ///     that the chat has real content worth persisting.
    public static func decide(
        newSid: String,
        previousKey: String,
        existingIds: Set<String>,
        firstUserMessageContent: String?
    ) -> Action {
        // Already tracking this sid (e.g. resume of a known session).
        if existingIds.contains(newSid) {
            return .noop
        }

        // Mid-stream sid change: the previous key's row IS this chat — just
        // rename it. This is the primary path that fixes the "empty New Session
        // entries piling up after compaction" bug.
        if previousKey != newSid, existingIds.contains(previousKey) {
            return .renameInPlace(from: previousKey, to: newSid)
        }

        // Truly unknown sid with no prior row to migrate. Only persist if the
        // chat has visible user content — otherwise we'd be inserting an empty
        // "New Session" row that the next `saveSession` would create anyway
        // once content arrives.
        if let content = firstUserMessageContent,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .insertNew(id: newSid, title: ChatSession.placeholderTitle(from: content))
        }

        return .noop
    }
}
