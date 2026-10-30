#if os(macOS)
import Foundation

public struct CodingAnalyticsExportProgress: Sendable {
    public enum Phase: Sendable { case histories, compressing, saving }
    public var phase: Phase
    public var completed: Int
    public var total: Int
}

public struct CodingAnalyticsArchiveResult: Sendable {
    public var sessionCount: Int
    public var unavailableHistoryCount: Int
}

/// All serialization, compression, and file operations run away from the main actor.
public actor CodingAnalyticsArchive {
    public init() {}

    private struct Manifest: Encodable {
        struct Session: Encodable {
            var sessionID: String
            var historyFile: String
            var historyStatus: String
            var messageCount: Int
        }
        var schemaVersion = 1
        var exportedAt = Date()
        var analyticsFile = "analytics.json"
        var sessions: [Session]
    }

    public func write(
        analytics: Data,
        sessions: [CodingAnalyticsSession],
        to destination: URL,
        history: @Sendable (CodingAnalyticsSession) async throws -> CodingChatHistoryExport,
        progress: @Sendable (CodingAnalyticsExportProgress) async -> Void
    ) async throws -> CodingAnalyticsArchiveResult {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("rxcode-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("contents", isDirectory: true)
        let histories = contents.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: histories, withIntermediateDirectories: true)
        try analytics.write(to: contents.appendingPathComponent("analytics.json"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var manifest = Manifest(sessions: [])
        await progress(.init(phase: .histories, completed: 0, total: sessions.count))
        for (index, record) in sessions.enumerated() {
            try Task.checkCancellation()
            let transcript = try await history(record)
            // Matches the historyFile each session carries in analytics.json.
            let path = CodingAnalyticsSession.historyFilePath(index: index)
            try encoder.encode(transcript).write(to: contents.appendingPathComponent(path), options: .atomic)
            manifest.sessions.append(.init(sessionID: record.id, historyFile: path,
                                           historyStatus: transcript.historyStatus, messageCount: transcript.messages.count))
            await progress(.init(phase: .histories, completed: index + 1, total: sessions.count))
        }
        try encoder.encode(manifest).write(to: contents.appendingPathComponent("manifest.json"), options: .atomic)
        try Self.readme.write(to: contents.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        await progress(.init(phase: .compressing, completed: sessions.count, total: sessions.count))
        let zip = temporary.appendingPathComponent("coding-analytics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", contents.path, zip.path]
        // Use a file rather than a pipe so verbose failures cannot deadlock compression.
        let log = temporary.appendingPathComponent("compression.log")
        _ = fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardError = output
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not compress the coding analytics archive."])
        }
        try Task.checkCancellation()
        await progress(.init(phase: .saving, completed: sessions.count, total: sessions.count))
        // Stage on the destination volume before replacing an existing, user-approved file.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".rxcode-export-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: zip, to: staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        return .init(sessionCount: sessions.count,
                     unavailableHistoryCount: manifest.sessions.filter { $0.historyStatus == "unavailable" }.count)
    }

    private static let readme = """
    RxCode coding analytics export, schema version 1

    analytics.json: Recorded prompts, model/provider history, timing, token usage and ratings.
    Each session's historyFile is the archive-relative path to its chat history.
    manifest.json: Maps session IDs to transcript files and reports unavailable histories.
    sessions/*.json: Full available chat history for each analytics-recorded session.

    Every provider (Claude Code, Codex, ACP) uses the same transcript schema:
    messages: id, role (user/assistant/system), timestamp (ISO 8601), content, attachments,
    isError, isStreaming, durationSeconds, isCompactBoundary.
    content is ordered: text {text}, tool_call {toolCallID, name, arguments},
    tool_result {toolCallID, text, isError}. Tool results reference their call IDs.
    Attachments contain name/path/type references; attachment files are not bundled.
    Streaming messages are snapshots as read during export. No provider is contacted.
    History may predate analytics recording. Deleted/unreadable histories are marked
    unavailable, rather than represented as successfully exported empty conversations.
    Each analytics turn may include usageLimits snapshots at start, result and end.
    These are cached observations with capturedAt/measuredAt timestamps and availability
    or staleness status. Provider account limits are shared quotas, not per-model costs.
    ACP snapshots retain provider-reported quota buckets without guessing model mappings.
    Missing usageLimits means the turn predates usage-limit recording.
    Missing token counts mean the provider did not report usage.
    """
}
#endif
