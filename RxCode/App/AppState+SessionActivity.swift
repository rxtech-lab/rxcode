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
    var liveTodos: TodoListSnapshot?
    var recordedTodos: TodoListSnapshot?

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
    func setViewedChat(_ sessionID: String?, for viewID: UUID) {
        viewedChatSessions[viewID] = sessionID
        if let sessionID { markCompletionRead(for: sessionID) }
    }

    func markCompletionRead(for sessionID: String) {
        let id = resolveCurrentSessionId(sessionID)
        guard sessionActivity[id]?.hasUncheckedCompletion == true else { return }
        updateState(id) { $0.hasUncheckedCompletion = false }
    }

    /// Called from `sessionStates.didSet`. Flags are projected synchronously
    /// (O(sessions), no transcript work) so status stays exact; todo extraction
    /// is coalesced onto a short timer.
    func sessionStatesDidChange() {
        var next = sessionActivity
        var flagsChanged = false
        var streamingChanged = false
        var needsTodoRefresh = false
        var previews: [String: [ComputerUseMonitorWindow]] = [:]
        for (id, state) in sessionStates {
            if state.isStreaming, !state.computerUseWindows.isEmpty {
                previews[id] = state.computerUseWindows
            }
            let previous = next[id]
            if previous?.isStreaming != state.isStreaming || previous?.hasUncheckedCompletion != state.hasUncheckedCompletion {
                var activity = previous ?? SessionActivity()
                activity.isStreaming = state.isStreaming
                activity.hasUncheckedCompletion = state.hasUncheckedCompletion
                next[id] = activity
                flagsChanged = true
                if (previous?.isStreaming ?? false) != state.isStreaming { streamingChanged = true }
            }
            if state.isStreaming || sessionActivityTodoFingerprints[id] != SessionActivity.TodoFingerprint(state) {
                needsTodoRefresh = true
            }
        }
        if next.count != sessionStates.count {
            for (id, activity) in next where sessionStates[id] == nil {
                next.removeValue(forKey: id)
                sessionActivityTodoFingerprints.removeValue(forKey: id)
                if activity.isStreaming { streamingChanged = true }
            }
            flagsChanged = true
        }
        if previews != computerUseWindowsBySession { computerUseWindowsBySession = previews }
        if flagsChanged { sessionActivity = next }
        if streamingChanged { scheduleDesktopWidgetUpdate() }
        if needsTodoRefresh {
            scheduleSessionActivityTodoRefresh()
        }
    }

    private func scheduleSessionActivityTodoRefresh() {
        sessionActivityTodoRefreshRequested = true
        guard sessionActivityTodoRefreshTask == nil else { return }
        sessionActivityTodoRefreshTask = Task { @MainActor [weak self] in
            repeat {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.sessionActivityTodoRefreshRequested = false
                await self.refreshSessionActivityTodos()
            } while self?.sessionActivityTodoRefreshRequested == true
            self?.sessionActivityTodoRefreshTask = nil
        }
    }

    /// Snapshot the message arrays, then replay task tools off the UI thread.
    /// One worker owns publication, so an older scan cannot finish after a newer one.
    private func refreshSessionActivityTodos() async {
        var messages: [String: [ChatMessage]] = [:]
        var fingerprints: [String: SessionActivity.TodoFingerprint] = [:]
        for (id, state) in sessionStates {
            let fingerprint = SessionActivity.TodoFingerprint(state)
            guard state.isStreaming || sessionActivityTodoFingerprints[id] != fingerprint else { continue }
            messages[id] = state.messages
            fingerprints[id] = fingerprint
        }
        guard !messages.isEmpty else { return }
        let snapshots = await Self.extractActivityTodos(from: messages)
        var next = sessionActivity
        var changed = false
        for (id, fingerprint) in fingerprints {
            guard let state = sessionStates[id], SessionActivity.TodoFingerprint(state) == fingerprint else { continue }
            sessionActivityTodoFingerprints[id] = fingerprint
            if next[id]?.liveTodos != snapshots[id] {
                next[id]?.liveTodos = snapshots[id]
                changed = true
            }
        }
        if changed { sessionActivity = next }
    }

    @concurrent
    private static func extractActivityTodos(from messages: [String: [ChatMessage]]) async -> [String: TodoListSnapshot] {
        messages.compactMapValues { TodoExtractor.latestSnapshot(in: $0) }
    }

    /// Streaming flag for the window's current session, read from
    /// `sessionActivity` so callers in view bodies (e.g. `.onChange`) don't
    /// subscribe to every `sessionStates` mutation.
    func isStreamingActivity(in window: WindowState) -> Bool {
        sessionActivity[window.currentSessionId ?? window.newSessionKey]?.isStreaming ?? false
    }

    /// Live todos for a session from the in-memory transcript, if any.
    func liveTodos(forSessionId id: String) -> TodoListSnapshot? {
        sessionActivity[id]?.liveTodos
    }

    func recordTodoSnapshot(_ items: [TodoItem], forSessionId id: String) {
        let sessionId = resolveCurrentSessionId(id)
        let snapshot = threadStore.upsertTodoSnapshot(sessionId: sessionId, items: items)
        publishTodoSnapshot(snapshot, forSessionId: sessionId)
    }

    func latestTodoSnapshot(forSessionId id: String) -> TodoListSnapshot? {
        let sessionId = resolveCurrentSessionId(id)
        let transcript = liveTodos(forSessionId: sessionId)
        let recorded = sessionActivity[sessionId]?.recordedTodos
            ?? todoProgressBySession[sessionId].flatMap { _ in
                threadStore.fetchTodoSnapshot(sessionId: sessionId)?.list
            }
        return TodoListSnapshot.latest(transcript: transcript, recorded: recorded)
    }

    /// Call after moving the persisted row during a session ID transition.
    func moveTodoSnapshotIndex(from oldId: String, to newId: String) {
        guard oldId != newId, todoProgressBySession[oldId] != nil else { return }
        publishTodoSnapshot(nil, forSessionId: oldId)
        publishTodoSnapshot(threadStore.fetchTodoSnapshot(sessionId: newId)?.list, forSessionId: newId)
    }

    private func publishTodoSnapshot(_ snapshot: TodoListSnapshot?, forSessionId id: String) {
        todoProgressBySession[id] = snapshot.map(ChatTodoProgress.init(snapshot:))
        sessionActivity[id]?.recordedTodos = snapshot
    }

    func computerUseMonitors(forSession id: String) -> [ComputerUseMonitorWindow] {
        computerUseWindowsBySession[id] ?? []
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
