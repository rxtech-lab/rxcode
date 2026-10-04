import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class GlobalSessionPersistenceTests: XCTestCase {
    private var root: URL!
    private var store: PersistenceService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meta = SessionMetaStore()
        store = PersistenceService(metaStore: meta, cliStore: CLISessionStore(metaStore: meta), baseURL: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
    }

    func testAllAppOwnedOriginsUseGlobalPathsAndKeepProjectContext() async throws {
        for origin in [SessionOrigin.legacyRxCode, .codexAppServer, .acpAgent] {
            let session = makeSession(id: origin.rawValue)
            var saved = session
            saved.origin = origin
            try await store.saveSession(saved)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/\(saved.id).json").path))
            let loaded = store.loadLegacySessionSync(projectId: UUID(), sessionId: saved.id)
            XCTAssertEqual(loaded?.projectId, saved.projectId)
            XCTAssertEqual(loaded?.messages.first?.content, "Transcript")
            XCTAssertEqual(loaded?.origin, origin)
        }
        let summaries = await store.loadAllLegacySessionSummaries()
        XCTAssertEqual(summaries.count, 3)
    }

    func testMigrationPreservesBytesAndIsRepeatable() async throws {
        var session = makeSession(id: "old-session")
        session.isPinned = true
        session.isArchived = true
        session.parentThreadId = "parent"
        session.threadLabel = "Review"
        session.skipHooks = true
        let oldURL = try writeLegacy(session)
        let original = try Data(contentsOf: oldURL)
        // Reading by global identity works even before migration.
        XCTAssertEqual(store.loadSessionSync(sessionId: session.id)?.messages.count, 1)

        await store.migrateSessionsToGlobalStorage()
        await store.migrateSessionsToGlobalStorage()

        XCTAssertEqual(try Data(contentsOf: store.sessionURL(sessionId: session.id)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        let summaries = await store.loadAllLegacySessionSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.parentThreadId, "parent")
        XCTAssertEqual(summaries.first?.skipHooks, true)
        let filtered = await store.loadLegacySessions(for: session.projectId)
        XCTAssertEqual(filtered.map(\.id), [session.id])
    }

    func testGlobalCopyWinsAndDeletionRemovesLegacyDuplicates() async throws {
        let session = makeSession(id: "duplicate")
        try await store.saveSession(session)
        var stale = session
        stale.title = "Old title"
        let oldURL = try writeLegacy(stale)
        await store.migrateSessionsToGlobalStorage()
        let summaries = await store.loadAllLegacySessionSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.title, session.title)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))

        try await store.deleteSession(projectId: UUID(), sessionId: session.id, origin: session.origin, cwd: nil)
        XCTAssertNil(store.loadSessionSync(sessionId: session.id))
        let remaining = await store.loadAllLegacySessionSummaries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMalformedLegacyFileIsRetainedAndDoesNotBlockMigration() async throws {
        let session = makeSession(id: "valid")
        let oldURL = try writeLegacy(session)
        let malformed = oldURL.deletingLastPathComponent().appendingPathComponent("broken.json")
        try Data("invalid json".utf8).write(to: malformed)
        await store.migrateSessionsToGlobalStorage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertNotNil(store.loadSessionSync(sessionId: session.id))
    }

    func testStartupBriefingCleanupRetainsSummariesForGlobalThreads() {
        let threads = ThreadStore.inMemory()
        let session = makeSession(id: "retained")
        threads.upsert(session.summary)
        threads.upsertThreadSummary(sessionId: session.id, projectId: session.projectId,
                                    branch: "main", title: session.title, summary: "Conversation summary")
        threads.upsertThreadSummary(sessionId: "missing", projectId: session.projectId,
                                    branch: "main", title: "Missing", summary: "Orphaned summary")
        let removed = threads.deleteBriefingMetadata(excludingProjectIds: [])
        XCTAssertEqual(removed.threadSummaries, 1)
        XCTAssertNotNil(threads.fetchThreadSummary(sessionId: session.id))
    }

    private func makeSession(id: String) -> ChatSession {
        ChatSession(id: id, projectId: UUID(), title: "Saved chat", messages: [
            ChatMessage(role: .user, content: "Transcript")
        ], origin: .codexAppServer)
    }

    private func writeLegacy(_ session: ChatSession) throws -> URL {
        let url = root.appendingPathComponent("sessions/\(session.projectId.uuidString)/\(session.id).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url)
        return url
    }
}
