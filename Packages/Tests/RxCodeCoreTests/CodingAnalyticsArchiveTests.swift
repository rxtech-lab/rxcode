#if os(macOS)
import Foundation
import Testing
@testable import RxCodeCore

private actor ExportProgressLog {
    var values: [CodingAnalyticsExportProgress] = []
    func append(_ value: CodingAnalyticsExportProgress) { values.append(value) }
}

struct CodingAnalyticsArchiveTests {
    @Test func unifiedMessagesPreserveContentOrderToolResultsAndAttachments() throws {
        let call = ToolCall(id: "call-1", name: "Read", input: ["path": .string("file.swift")], result: "source", isError: true)
        var message = ChatMessage(role: .assistant, blocks: [.text("Before"), .toolCall(call), .text("After")], isStreaming: true)
        message.attachmentPaths = [AttachmentInfo(name: "photo.png", path: "/private/photo.png", type: "image")]
        let export = CodingChatHistoryExport(sessionID: "thread", title: "Test", messages: [message])
        let unified = try #require(export.messages.first)
        #expect(unified.role == "assistant")
        #expect(unified.content.map(\.type) == ["text", "tool_call", "tool_result", "text"])
        #expect(unified.content[1].arguments?["path"] == .string("file.swift"))
        #expect(unified.content[2].toolCallID == "call-1")
        #expect(unified.content[2].text == "source")
        #expect(unified.content[2].isError == true)
        #expect(unified.attachments == message.attachmentPaths)
        #expect(unified.isStreaming)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(CodingChatHistoryExport.self, from: encoder.encode(export))
        #expect(roundTrip.messages.first?.id == message.id)
    }

    @Test func zipContainsAnalyticsAndUnifiedHistoriesForAllProvidersWithProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CodingAnalyticsStore(url: folder.appendingPathComponent("analytics-source.json"))
        for provider in ["claudeCode", "codex", "acp"] {
            try await store.begin(threadID: provider, projectID: UUID(), turnID: UUID(), prompt: "你好",
                                  provider: provider, clientID: provider == "acp" ? "opencode" : nil, model: "test")
        }
        let snapshot = try await store.exportSnapshot()
        let zip = folder.appendingPathComponent("export.zip")
        // Exercise safe replacement of a previously exported archive.
        try Data("previous".utf8).write(to: zip)
        let log = ExportProgressLog()
        let result = try await CodingAnalyticsArchive().write(analytics: snapshot.analytics, sessions: snapshot.sessions, to: zip,
            history: { record in
                CodingChatHistoryExport(sessionID: record.id, title: record.id,
                                        messages: [ChatMessage(role: .user, content: "你好"), ChatMessage(role: .assistant, content: "Done")])
            }, progress: { await log.append($0) })
        #expect(result.sessionCount == 3)
        #expect(result.unavailableHistoryCount == 0)
        let manifest = try JSONSerialization.jsonObject(with: unzip(zip, path: "manifest.json")) as? [String: Any]
        let entries = try #require(manifest?["sessions"] as? [[String: Any]])
        #expect(Set(entries.compactMap { $0["sessionID"] as? String }) == ["claudeCode", "codex", "acp"])
        for entry in entries {
            let file = try #require(entry["historyFile"] as? String)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let history = try decoder.decode(CodingChatHistoryExport.self, from: unzip(zip, path: file))
            #expect(history.messages.map(\.role) == ["user", "assistant"])
            #expect(history.messages.first?.content.first?.text == "你好")
        }
        #expect(try unzip(zip, path: "analytics.json") == snapshot.analytics)
        let analytics = try JSONSerialization.jsonObject(with: snapshot.analytics) as? [String: Any]
        let analyticsSessions = try #require(analytics?["sessions"] as? [[String: Any]])
        let manifestFiles = Dictionary(uniqueKeysWithValues: entries.map { ($0["sessionID"] as! String, $0["historyFile"] as! String) })
        for session in analyticsSessions {
            let id = try #require(session["id"] as? String)
            let file = try #require(session["historyFile"] as? String)
            #expect(file == manifestFiles[id])
            #expect(try !unzip(zip, path: file).isEmpty)
        }
        #expect(try !unzip(zip, path: "README.txt").isEmpty)
        let progress = await log.values
        #expect(progress.filter { if case .histories = $0.phase { true } else { false } }.map(\.completed) == [0, 1, 2, 3])
        #expect(progress.contains { if case .compressing = $0.phase { true } else { false } })
        #expect(progress.contains { if case .saving = $0.phase { true } else { false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["analytics-source.json", "export.zip"])
    }

    @Test func unavailableHistoryIsExplicitAndSessionIDsCannotEscapeTheArchive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CodingAnalyticsStore(url: folder.appendingPathComponent("source.json"))
        try await store.begin(threadID: "../../outside", projectID: UUID(), turnID: UUID(), prompt: "test",
                              provider: "codex", clientID: nil, model: nil)
        let snapshot = try await store.exportSnapshot()
        let zip = folder.appendingPathComponent("export.zip")
        let result = try await CodingAnalyticsArchive().write(analytics: snapshot.analytics, sessions: snapshot.sessions, to: zip,
            history: { CodingChatHistoryExport(sessionID: $0.id, title: nil, messages: nil) }, progress: { _ in })
        #expect(result.unavailableHistoryCount == 1)
        let json = try JSONSerialization.jsonObject(with: unzip(zip, path: "sessions/000001.json")) as? [String: Any]
        #expect(json?["historyStatus"] as? String == "unavailable")
        #expect(json?["sessionID"] as? String == "../../outside")
    }

    @Test func emptyExportStillProducesValidZip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("empty.zip")
        let result = try await CodingAnalyticsArchive().write(analytics: Data("{}".utf8), sessions: [], to: zip,
            history: { CodingChatHistoryExport(sessionID: $0.id, title: nil, messages: nil) }, progress: { _ in })
        #expect(result.sessionCount == 0)
        #expect(try unzip(zip, path: "analytics.json") == Data("{}".utf8))
    }

    private func unzip(_ url: URL, path: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return result
    }
}
#endif
