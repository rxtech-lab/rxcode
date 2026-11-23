import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class LocalPlanReplayTests: XCTestCase {
    func testReplayOriginalPlanThroughToolDispatcherAndPetReport() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/plan-replay-_6j9_7i0")
        let stored = try Data(contentsOf: base.appendingPathComponent("plan.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ChatSession.self, from: Data(contentsOf: base.appendingPathComponent("session.json")))
        let original = try JSONDecoder().decode(CodingPlan.self, from: stored)
        let persistence = MockAppStatePersistence()
        await persistence.stubFullSession(session)
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        app.threadStore = .inMemory()
        app.projects = [Project(id: session.projectId, name: "RxCode", path: base.path)]
        app.threadStore.upsert(session.summary)
        let row = try XCTUnwrap(app.threadStore.fetch(id: session.id))
        row.codingPlanData = stored
        try app.threadStore.context.save()
        func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            let result = try await app.ideHandleToolCall(name: name, arguments: .object(args), sessionKey: "pet-test")
            let body = try XCTUnwrap(result["content"]?[0]?["text"]?.stringValue)
            return try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        }
        let chat = try await call("ide__get_thread_messages", ["thread_id": .string(session.id)])
        XCTAssertEqual(chat["messages"]?.arrayValue?.count, 1)
        let list = try await call("ide__list_coding_plans", ["project_id": .string(session.projectId.uuidString)])
        XCTAssertEqual(list["plans"]?[0]?["plan_id"]?.stringValue, session.id)
        XCTAssertEqual(list["plans"]?[0]?["implementation_status"]?.stringValue, "unimplemented")
        let versions = try await call("ide__list_coding_plan_versions", ["plan_id": .string(session.id)])
        XCTAssertEqual(versions["versions"]?.arrayValue?.count, 4)
        for version in original.versions {
            let response = try await call("ide__get_coding_plan_version", ["plan_id": .string(session.id), "version_id": .string(version.id.uuidString)])
            XCTAssertEqual(response["version"]?["markdown"]?.stringValue, version.markdown)
            print("Replay:", version.title, version.id, version.markdown.utf8.count, "bytes")
        }
        app.workspaceDefaults = WorkspaceDefaults(workspaceID: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let companion = PetController(defaults: defaults)
        companion.configuration.customAgent = .init(provider: .flowcy, model: "test")
        let report = await PetDailyReportService.generate(for: app, companion: companion)
        XCTAssertTrue(report.markdownBody.contains(session.id))
        XCTAssertTrue(report.markdownBody.contains("Unimplemented (1)"))
        XCTAssertTrue(report.markdownBody.contains("signed macOS app extension"))
        XCTAssertEqual(row.codingPlanData, stored)
        print("Replay pet narrative:", report.spokenSummary)
    }
}
