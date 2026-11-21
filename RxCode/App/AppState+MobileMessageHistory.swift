import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    /// Number of messages in one mobile history page. Mobile loads the most
    /// recent page on subscribe and requests older pages as the user scrolls up.
    static let mobileMessagePageSize = 30

    /// Encoded byte ceiling for the message slice carried in one sync frame.
    /// The relay caps a WebSocket frame at 10 MiB and the encrypted envelope
    /// inflates the plaintext by roughly a third (base64), so an oversized
    /// snapshot would have `task.send` throw and be silently dropped — leaving
    /// mobile with only the live stream and no history. Holding the message
    /// slice to 3 MiB leaves ample room for the rest of the snapshot (projects,
    /// session summaries, briefings) and the envelope overhead; older messages
    /// beyond the budget are paged in on demand via `load_more_messages`.
    static let mobileMessagePageByteBudget = 3 * 1024 * 1024

    /// Largest suffix of `messages[..<end]` that fits both the page-count and
    /// byte budgets, walking newest-first. At least one message is always
    /// returned so paging can still advance even on a pathologically large
    /// message. Returns the page and the index it starts at — a non-zero start
    /// means older messages remain.
    func mobileMessagePage(
        from messages: [ChatMessage],
        endingAt end: Int,
        countLimit: Int
    ) -> (page: [ChatMessage], startIndex: Int) {
        let clampedEnd = min(max(end, 0), messages.count)
        guard clampedEnd > 0, countLimit > 0 else { return ([], clampedEnd) }
        let encoder = JSONEncoder()
        var startIndex = clampedEnd
        var byteCount = 0
        var index = clampedEnd - 1
        while index >= 0 {
            let size = (try? encoder.encode(messages[index]))?.count ?? 0
            let takenSoFar = clampedEnd - startIndex
            // Always accept the newest message; afterwards stop once either
            // budget would be exceeded so the frame stays under the relay cap.
            if takenSoFar > 0,
               takenSoFar >= countLimit
                || byteCount + size > Self.mobileMessagePageByteBudget {
                break
            }
            byteCount += size
            startIndex = index
            index -= 1
        }
        return (Array(messages[startIndex ..< clampedEnd]), startIndex)
    }

    /// Single-entry cache of a disk-loaded session's full message list. Mobile
    /// pages one thread at a time, so caching just the most recent one lets the

    /// Resolve the full, cleaned message list for a session — from live stream
    /// state when available, otherwise from disk (cached). `nil` only when the
    /// session genuinely can't be located.
    func fullMobileMessages(for resolvedID: String) async -> [ChatMessage]? {
        if let state = sessionStates[resolvedID] {
            return messagesWithPlanDecisions(
                rehydrateDetectedToolChanges(in: cleanLoadedMessages(state.messages), sessionId: resolvedID),
                summaries: state.planDecisionSummaries
            )
        }
        // Non-active session: the in-memory sidecar is absent, so pull the
        // persisted decisions from the thread store.
        let summaries = threadStore.loadPlanDecisions(sessionId: resolvedID)
        if let cache = mobileFullMessageCache, cache.sessionID == resolvedID {
            return messagesWithPlanDecisions(
                rehydrateDetectedToolChanges(in: cache.messages, sessionId: resolvedID),
                summaries: summaries
            )
        }
        guard let summary = allSessionSummaries.first(where: { $0.id == resolvedID }),
              let project = projects.first(where: { $0.id == summary.projectId }),
              let full = await persistence.loadFullSession(summary: summary, cwd: project.path)
        else {
            return nil
        }
        let cleaned = rehydrateDetectedToolChanges(
            in: cleanLoadedMessages(full.messages),
            sessionId: resolvedID
        )
        mobileFullMessageCache = (resolvedID, cleaned)
        return messagesWithPlanDecisions(cleaned, summaries: summaries)
    }

    /// Bake persisted plan decisions into `ExitPlanMode` tool results before
    /// messages are sent to mobile. Once a plan resolves, the CLI overwrites the
    /// tool result with its own follow-up text ("User has approved your plan…"),
    /// which the desktop UI sidesteps with the `planDecisionSummaries` sidecar.
    /// Mobile has no such sidecar — it reads `toolCall.result` directly — so the
    /// user-decision summary must be written onto the wire result, otherwise the
    /// mobile plan banner reappears after a decision.
    func messagesWithPlanDecisions(
        _ messages: [ChatMessage],
        summaries: [String: String]
    ) -> [ChatMessage] {
        guard !summaries.isEmpty else { return messages }
        return messages.map { messageWithPlanDecisions($0, summaries: summaries) }
    }

    func messageWithPlanDecisions(
        _ message: ChatMessage,
        summaries: [String: String]
    ) -> ChatMessage {
        guard !summaries.isEmpty else { return message }
        var result = message
        for block in message.blocks {
            guard let toolCall = block.toolCall,
                  PlanLogic.isExitPlanMode(toolCall),
                  let summary = summaries[toolCall.id] else { continue }
            // Skip when the result is already the user-decision string.
            if toolCall.result.map(PlanDecisionAction.isUserDecisionResult) != true {
                result.setToolResult(id: toolCall.id, result: summary, isError: false)
            }
        }
        return result
    }

    /// Build the active-session payload for a snapshot: only the most recent
    /// page of messages, plus whether older messages remain. Mobile pages the
    /// rest in via `load_more_messages` so a snapshot never carries a whole
    /// (potentially multi-MB) thread history in one frame.
    func mobileActiveSessionPayload(
        for requestedID: String?
    ) async -> (id: String?, messages: [ChatMessage]?, hasMore: Bool) {
        guard let requestedID else { return (nil, nil, false) }
        let resolvedID = resolveCurrentSessionId(requestedID)
        guard let all = await fullMobileMessages(for: resolvedID) else {
            return (nil, nil, false)
        }
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: all.count,
            countLimit: Self.mobileMessagePageSize
        )
        return (resolvedID, page, startIndex > 0)
    }

    /// Reply to a mobile `load_more_messages` request with the page of messages
    /// immediately older than `beforeMessageID`.
    func handleMobileLoadMoreMessages(
        _ request: LoadMoreMessagesRequestPayload,
        fromHex: String
    ) async {
        let resolvedID = resolveCurrentSessionId(request.sessionID)
        let all = await fullMobileMessages(for: resolvedID) ?? []
        guard let anchorIndex = all.firstIndex(where: { $0.id == request.beforeMessageID }) else {
            // The anchor is gone (thread changed, or never loaded). Stop paging.
            await MobileSyncService.shared.send(
                .moreMessages(MoreMessagesPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    messages: [],
                    hasMore: false
                )),
                toHex: fromHex
            )
            return
        }
        let limit = max(1, request.limit)
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: anchorIndex,
            countLimit: limit
        )
        await MobileSyncService.shared.send(
            .moreMessages(MoreMessagesPayload(
                clientRequestID: request.clientRequestID,
                sessionID: request.sessionID,
                messages: page,
                hasMore: startIndex > 0
            )),
            toHex: fromHex
        )
    }

    /// Builds the change overview for the mobile "View Changes" sheet: every
    /// file edited in the thread session plus the project's uncommitted git
    /// changes. Replies with a `threadChangesResult`.
    func handleMobileThreadChangesRequest(
        _ request: ThreadChangesRequestPayload,
        fromHex hex: String
    ) async {
        // A tool result can reach mobile before its asynchronous file scan ends.
        await awaitPendingShellDetections(for: request.sessionID)
        let resolvedID = resolveCurrentSessionId(request.sessionID)

        // This Turn: every file edited in the thread session (SwiftData history).
        let editSummaries = threadStore.fetchFileEdits(sessionId: resolvedID)
            .map { $0.toSummary() }
            .filter { !PlanLogic.isPlanFilePath($0.path) }
        let unboundedEdits = await withTaskGroup(of: (Int, SyncFileEdit).self) { group in
            for (index, summary) in editSummaries.enumerated() {
                group.addTask {
                    let fullFileDiff = await Self.mobileFullFileDiff(
                        path: summary.path,
                        hunks: summary.hunks,
                        originalContent: summary.originalContent,
                        isDeleted: summary.isDeleted,
                        preferHunks: summary.hasExternalInterleaving
                    )
                    return (index, SyncFileEdit(
                        path: summary.path,
                        name: summary.name,
                        containsWrite: summary.containsWrite,
                        hunks: summary.hunks.map {
                            SyncEditHunk(oldString: $0.oldString, newString: $0.newString)
                        },
                        fullFileDiff: fullFileDiff,
                        originalContent: summary.hasExternalInterleaving ? nil : summary.originalContent,
                        modifiedContent: summary.hasExternalInterleaving ? nil : summary.modifiedContent
                    ))
                }
            }

            var ordered = Array<SyncFileEdit?>(repeating: nil, count: editSummaries.count)
            for await (index, edit) in group {
                ordered[index] = edit
            }
            return ordered.compactMap(\.self)
        }
        // The relay caps each encrypted envelope at 10 MiB. A long thread of
        // large-file edits can easily exceed that once every file's full
        // before/after snapshot is included, and the oversize send is dropped
        // silently — leaving the mobile sheet stuck on "Loading changes…".
        // Drop snapshots that would push the reply past a conservative budget;
        // mobile falls back to `fullFileDiff` / `hunks` when snapshots are nil.
        let turnEdits = Self.applySnapshotBudget(to: unboundedEdits)

        func reply(ok: Bool, error: String?, uncommitted: [SyncGitChange]) async {
            await MobileSyncService.shared.send(
                .threadChangesResult(ThreadChangesResultPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    ok: ok,
                    errorMessage: error,
                    turnEdits: turnEdits,
                    uncommitted: uncommitted
                )),
                toHex: hex
            )
        }

        // Uncommitted: the session's project working tree.
        let projectPath = allSessionSummaries
            .first(where: { $0.id == resolvedID })
            .flatMap { summary in projects.first(where: { $0.id == summary.projectId })?.path }

        guard let projectPath, !projectPath.isEmpty else {
            await reply(ok: false, error: "This thread has no associated project folder.", uncommitted: [])
            return
        }

        guard let gitChanges = await GitHelper.uncommittedChanges(at: projectPath) else {
            await reply(ok: false, error: "This project is not a git repository.", uncommitted: [])
            return
        }

        let uncommitted = gitChanges.map { change -> SyncGitChange in
            let kind: SyncGitChangeKind = switch change.kind {
            case .staged: .staged
            case .unstaged: .unstaged
            case .untracked: .untracked
            }
            return SyncGitChange(
                displayPath: change.displayPath,
                statusChar: change.statusChar,
                kind: kind,
                unifiedDiff: change.unifiedDiff,
                truncated: change.truncated
            )
        }
        await reply(ok: true, error: nil, uncommitted: uncommitted)
    }

    func handleMobileRemoteFileRequest(
        _ request: RemoteFileRequestPayload,
        fromHex hex: String
    ) async {
        let path = URL(fileURLWithPath: request.path).standardizedFileURL.path
        let name = URL(fileURLWithPath: path).lastPathComponent

        func reply(ok: Bool, error: String?, content: String? = nil, truncated: Bool = false) async {
            await MobileSyncService.shared.send(
                .remoteFileResult(RemoteFileResultPayload(
                    clientRequestID: request.clientRequestID,
                    path: path,
                    name: name.isEmpty ? path : name,
                    line: request.line,
                    ok: ok,
                    errorMessage: error,
                    content: content,
                    truncated: truncated
                )),
                toHex: hex
            )
        }

        guard Self.isPath(path, underAnyProject: projects.map(\.path)) else {
            await reply(ok: false, error: "This file is outside your RxCode projects.")
            return
        }

        do {
            let result = try await Task.detached {
                try Self.readMobilePreviewFile(path: path)
            }.value
            await reply(ok: true, error: nil, content: result.content, truncated: result.truncated)
        } catch let error as MobileRemoteFileReadError {
            await reply(ok: false, error: error.localizedDescription)
        } catch {
            await reply(ok: false, error: "Read failed: \(error.localizedDescription)")
        }
    }
}
