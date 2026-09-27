import Foundation
import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class CacheStorageTests: XCTestCase {
    private static var retainedStores: [ThreadStore] = []

    func testClearingCachedRecordsPreservesChats() throws {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        let projectId = UUID()
        store.context.insert(ChatThread(id: "thread-1", projectId: projectId, title: "Keep chat"))
        store.upsertThreadSummary(
            sessionId: "thread-1", projectId: projectId, branch: "main",
            title: "Summary", summary: "Cached summary"
        )
        store.upsertBranchBriefing(projectId: projectId, branch: "main", briefing: "Cached briefing")
        store.context.insert(ThreadEmbeddingChunk(
            id: "thread-1#0", threadId: "thread-1", projectId: projectId,
            chunkIndex: 0, text: "Cached chunk", vector: Data(), dim: 0
        ))
        store.save()

        try store.clearCachedRecords()

        XCTAssertEqual(store.loadAllSummaries().map(\.title), ["Keep chat"])
        XCTAssertTrue(store.allThreadSummaryItems().isEmpty)
        XCTAssertTrue(store.allBranchBriefingItems().isEmpty)
        XCTAssertTrue(store.loadAllEmbeddingChunks().isEmpty)
    }

    func testBreakdownExplainsRetainedSpaceAfterClearingFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let compiled = root.appendingPathComponent("compiled", isDirectory: true)
        let workspace = support.appendingPathComponent("workspaces/example", isDirectory: true)

        func write(_ path: String, bytes: Int, under directory: URL? = nil) throws {
            let url = (directory ?? support).appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: bytes).write(to: url)
        }

        try write("attachments/image.png", bytes: 100)
        try write("sessions/chat.json", bytes: 80)
        try write("threads.store", bytes: 60)
        try write("diagnostics/log.txt", bytes: 10)
        try write("workspaces/example/task_board/tasks.json", bytes: 20)
        try write("workspaces/example/attachments/asset.png", bytes: 4)
        try write("workspaces/example/sessions/chat.json", bytes: 6)
        try write("workspaces/example/briefings/document/content.md", bytes: 30)
        try write("settings.json", bytes: 2)
        try write("icon.svg", bytes: 5, under: cache)
        try write("filter", bytes: 15, under: compiled)

        let service = CacheStorageService(
            appSupportRoot: support, cacheRoot: cache, compiledCacheRoots: [compiled]
        )
        let before = await service.breakdown()
        XCTAssertEqual(before.attachments, 104)
        XCTAssertEqual(before.sessions, 86)
        XCTAssertEqual(before.threadDatabase, 60)
        XCTAssertEqual(before.workspaces, 20)
        XCTAssertEqual(before.diagnostics, 10)
        XCTAssertEqual(before.clearableFiles, 50)
        XCTAssertEqual(before.other, 2)
        XCTAssertEqual(before.totalBytes, 332)

        try await service.clearFileCaches(workspaceURLs: [workspace])
        let after = await service.breakdown()
        XCTAssertEqual(after.clearableFiles, 0)
        XCTAssertEqual(after.totalBytes, 282)
        XCTAssertTrue(fileManager.fileExists(atPath: support.appendingPathComponent("attachments/image.png").path))
        XCTAssertTrue(fileManager.fileExists(atPath: support.appendingPathComponent("sessions/chat.json").path))
    }
}
