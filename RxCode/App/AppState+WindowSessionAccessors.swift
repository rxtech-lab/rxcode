import Foundation
import struct RxAgentSDK.ClaudeCodeClient
import os
import RxAuthSwift
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Window-Scoped Session State Accessors

    func streamState(in window: WindowState) -> SessionStreamState {
        sessionStates[window.currentSessionId ?? window.newSessionKey] ?? SessionStreamState()
    }

    func messages(in window: WindowState) -> [ChatMessage] {
        streamState(in: window).messages
    }

    func threadFileEditsLoadID(sessionId: String) -> ThreadFileEditsLoadID {
        ThreadFileEditsLoadID(sessionId: resolveCurrentSessionId(sessionId), revision: threadFileEditsRevision)
    }

    func loadThreadDiffPreview(sessionId: String) async -> [FileEditSummary] {
        await loadThreadDiffPreview(threadFileEditsLoadID(sessionId: sessionId))
    }

    func loadThreadDiffPreview(_ loadID: ThreadFileEditsLoadID) async -> [FileEditSummary] {
        if let inFlight = threadDiffLoads[loadID] {
            return await inFlight.value
        }
        // The banner and inspector can request the same snapshot concurrently.
        let read = Task { [threadStoreReader] in
            await threadStoreReader.loadThreadDiffPreview(sessionId: loadID.sessionId)
        }
        threadDiffLoads[loadID] = read
        defer { threadDiffLoads.removeValue(forKey: loadID) }
        return await read.value
    }

    func isStreaming(in window: WindowState) -> Bool {
        streamState(in: window).isStreaming
    }

    func isThinking(in window: WindowState) -> Bool {
        streamState(in: window).isThinking
    }

    func streamingStartDate(in window: WindowState) -> Date? {
        streamState(in: window).streamingStartDate
    }

    func activeModelName(in window: WindowState) -> String? {
        streamState(in: window).activeModelName
    }

    func lastTurnContextUsedPercentage(in window: WindowState) -> Double? {
        streamState(in: window).lastTurnContextUsedPercentage
    }

    func sessionCostUsd(in window: WindowState) -> Double {
        streamState(in: window).costUsd
    }

    func sessionTurns(in window: WindowState) -> Int {
        streamState(in: window).turns
    }

    func sessionInputTokens(in window: WindowState) -> Int {
        streamState(in: window).inputTokens
    }

    func sessionOutputTokens(in window: WindowState) -> Int {
        streamState(in: window).outputTokens
    }

    func sessionCacheCreationTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheCreationTokens
    }

    func sessionCacheReadTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheReadTokens
    }

    func sessionDurationMs(in window: WindowState) -> Double {
        streamState(in: window).durationMs
    }

    func currentSession(in window: WindowState) -> ChatSession? {
        guard let id = window.currentSessionId else { return nil }
        guard let summary = allSessionSummaries.first(where: { $0.id == id }) else { return nil }
        return summary.makeSession()
    }

    /// Check whether a given session is streaming in the background (not foreground) of this window
    func isBackgroundStreaming(_ sessionId: String, in window: WindowState) -> Bool {
        guard sessionId != (window.currentSessionId ?? window.newSessionKey) else { return false }
        return sessionStates[sessionId]?.isStreaming ?? false
    }

    /// Returns the set of session IDs currently streaming in the background of this window.
    func backgroundStreamingSessionIds(in window: WindowState) -> Set<String> {
        let currentKey = window.currentSessionId ?? window.newSessionKey
        return Set(sessionActivity.compactMap { key, activity in
            (activity.isStreaming && key != currentKey) ? key : nil
        })
    }

    /// Derive a UI status for the chat row in the project sidebar.
    func chatStatus(forSessionId id: String, in window: WindowState) -> ChatStatus {
        if window.pendingPermissions.contains(where: { $0.sessionId == id }) {
            return .awaitingPermission
        }
        // `sessionActivity`, not `sessionStates`: this runs in every sidebar row's
        // body, and reading `sessionStates` re-rendered them all per stream event.
        if let activity = sessionActivity[id] {
            if activity.isStreaming { return .streaming }
            if activity.hasUncheckedCompletion { return .done }
        }
        return .idle
    }

    func todoProgress(forSessionId id: String) -> ChatTodoProgress? {
        // Live todos are extracted off the hot path into `sessionActivity`
        // instead of rescanning the whole transcript per row per render.
        // Read the persisted fallback from the in-memory index rather than
        // fetching per call: the sidebar asks this for every visible thread on
        // every view-graph update, where a SwiftData fetch would land on the
        // main thread at display-link rate.
        let recorded = todoProgressBySession[id]
        if let live = liveTodos(forSessionId: id), live.updatedAt > (recorded?.updatedAt ?? .distantPast) {
            return live.items.isEmpty ? nil : ChatTodoProgress(snapshot: live)
        }
        return recorded.flatMap { $0.total > 0 ? $0 : nil }
    }
}
