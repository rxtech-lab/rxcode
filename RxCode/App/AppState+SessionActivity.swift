import Foundation
import RxCodeCore

/// Per-session status that chrome outside the transcript needs: sidebar rows,
/// briefing cards, the menu bar label, the toolbar todo pill.
///
/// Those views used to read `sessionStates` directly. That dictionary is
/// mutated many times per stream event (text-delta flushes, timestamps, tool
/// buffers), and because it is a single observable property, every mutation
/// re-rendered every reader — the whole project tree, every row's eagerly
/// built context menu (hooks + SwiftData fetch), and a full-transcript todo
/// scan per visible row. The cost grew with the number and length of loaded
/// threads, which is why the app got slower the longer it ran.
struct SessionActivity: Equatable {
    var isStreaming = false
    var hasUncheckedCompletion = false
    /// Latest todo list reconstructed from in-memory messages, or `nil` when the
    /// transcript has none (callers fall back to the persisted snapshot).
    var liveTodos: [TodoItem]?

    /// Cheap summary of a session's transcript tail. Todos are only re-extracted
    /// when this changes (or while the session is streaming, since a tool call's
    /// input/result can change in place).
    struct TodoFingerprint: Equatable {
        let messageCount: Int
        let lastMessageId: UUID?
        let lastMessageBlockCount: Int
        let isStreaming: Bool

        init(_ state: SessionStreamState) {
            messageCount = state.messages.count
            lastMessageId = state.messages.last?.id
            lastMessageBlockCount = state.messages.last?.blocks.count ?? 0
            isStreaming = state.isStreaming
        }
    }
}

extension AppState {
    /// Called from `sessionStates.didSet`. Flags are projected synchronously
    /// (O(sessions), no transcript work) so status stays exact; todo extraction
    /// is coalesced onto a short timer.
    func sessionStatesDidChange() {
        var next = sessionActivity
        var needsTodoRefresh = false
        for (id, state) in sessionStates {
            var activity = next[id] ?? SessionActivity()
            activity.isStreaming = state.isStreaming
            activity.hasUncheckedCompletion = state.hasUncheckedCompletion
            next[id] = activity
            if state.isStreaming || sessionActivityTodoFingerprints[id] != SessionActivity.TodoFingerprint(state) {
                needsTodoRefresh = true
            }
        }
        if next.count != sessionStates.count {
            next = next.filter { sessionStates[$0.key] != nil }
            sessionActivityTodoFingerprints = sessionActivityTodoFingerprints.filter { sessionStates[$0.key] != nil }
        }

        // Assigning an equal value still fires observation — only publish real changes.
        if next != sessionActivity {
            sessionActivity = next
        }
        if needsTodoRefresh {
            scheduleSessionActivityTodoRefresh()
        }
    }

    private func scheduleSessionActivityTodoRefresh() {
        guard sessionActivityTodoRefreshTask == nil else { return }
        sessionActivityTodoRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.sessionActivityTodoRefreshTask = nil
            self.refreshSessionActivityTodos()
        }
    }

    private func refreshSessionActivityTodos() {
        var next = sessionActivity
        for (id, state) in sessionStates {
            let fingerprint = SessionActivity.TodoFingerprint(state)
            guard state.isStreaming || sessionActivityTodoFingerprints[id] != fingerprint else { continue }
            sessionActivityTodoFingerprints[id] = fingerprint
            next[id, default: SessionActivity(
                isStreaming: state.isStreaming,
                hasUncheckedCompletion: state.hasUncheckedCompletion
            )].liveTodos = TodoExtractor.latest(in: state.messages)
        }
        if next != sessionActivity {
            sessionActivity = next
        }
    }

    /// Streaming flag for the window's current session, read from
    /// `sessionActivity` so callers in view bodies (e.g. `.onChange`) don't
    /// subscribe to every `sessionStates` mutation.
    func isStreamingActivity(in window: WindowState) -> Bool {
        sessionActivity[window.currentSessionId ?? window.newSessionKey]?.isStreaming ?? false
    }

    /// Live todos for a session from the in-memory transcript, if any.
    func liveTodos(forSessionId id: String) -> [TodoItem]? {
        sessionActivity[id]?.liveTodos
    }

    /// Enabled custom menu rows for `projectId`/`surface`, served from a cache
    /// invalidated by `customMenuItemsRevision` (bumped on every edit).
    func cachedCustomMenuItems(projectId: UUID?, surface: CustomMenuItemRecord.Surface) -> [CustomMenuItemRecord] {
        let revision = customMenuItemsRevision
        let rows: [CustomMenuItemRecord]
        if let cache = customMenuItemsCache, cache.revision == revision {
            rows = cache.rows
        } else {
            rows = threadStore.enabledCustomMenuItems()
            customMenuItemsCache = (revision, rows)
        }
        return rows.filter {
            ($0.projectId == nil || $0.projectId == projectId) && $0.surfaces.contains(surface)
        }
    }
}
