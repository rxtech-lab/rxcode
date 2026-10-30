import Foundation
import RxCodeCore

extension AppState {
    func exportCodingAnalytics(
        to destination: URL,
        progress: @escaping @Sendable (CodingAnalyticsExportProgress) async -> Void
    ) async throws -> CodingAnalyticsArchiveResult {
        let snapshot = try await CodingAnalyticsRecorder.shared.exportSnapshot()
        return try await CodingAnalyticsArchive().write(
            analytics: snapshot.analytics, sessions: snapshot.sessions, to: destination,
            history: { record in
                let source = await self.codingAnalyticsHistorySource(record)
                return CodingChatHistoryExport(sessionID: record.id, title: source.title, messages: source.messages)
            }, progress: progress
        )
    }

    private func codingAnalyticsHistorySource(_ record: CodingAnalyticsSession) async -> (title: String?, messages: [ChatMessage]?) {
        let summary = threadStore.fetch(id: record.id)?.toSummary()
            ?? allSessionSummaries.first { $0.id == record.id }
        // Include unsaved streaming content without changing or persisting the chat.
        if let state = sessionStates[record.id], !state.isLoadingFromDisk, !state.messages.isEmpty {
            return (summary?.title, state.messages)
        }
        guard let summary else { return (nil, nil) }
        let cwd = summary.worktreePath ?? sessionProject(id: summary.projectId)?.path ?? ""
        let session = await persistence.loadFullSession(summary: summary, cwd: cwd)
        return (summary.title, session?.messages)
    }
}
