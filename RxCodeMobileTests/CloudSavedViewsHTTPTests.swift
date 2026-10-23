import Foundation
import RxCodeCore
import XCTest
@testable import RxCodeMobile

@MainActor
final class CloudSavedViewsHTTPTests: XCTestCase {
    /// Run with TEST_RUNNER_RXCODE_VIEWS_SIMULATION_URL=http://127.0.0.1:4912/flowcy
    /// and the saved Postman simulation. No credentials or live writes are used.
    func testSavedViewsRoundTripConflictAndLegacyServerOverHTTP() async throws {
        guard let address = ProcessInfo.processInfo.environment["RXCODE_VIEWS_SIMULATION_URL"],
              let baseURL = URL(string: address) else { throw XCTSkip("Start the saved board-views Postman simulation to run HTTP coverage.") }
        let api = ProjectCloudService(session: .shared, baseURL: baseURL) { _ in "simulation-\(UUID().uuidString)" }
        // A stable simulated account lets both devices read the same preferences.
        let account = "simulation-\(UUID().uuidString)"
        let mac = ProjectCloudService(session: .shared, baseURL: baseURL) { _ in account }
        let phone = ProjectCloudService(session: .shared, baseURL: baseURL) { _ in account }
        let response = try await mac.savedViews(projectId: "project")
        let initial = try XCTUnwrap(response)
        XCTAssertEqual(initial.revision, 0)
        let view = CloudSavedView(view: TaskSavedView(name: "v1.20.0", versions: ["v1.20.0"], isDefault: true), sync: CloudBoardSyncState())
        let saved = try await mac.saveViews(CloudSavedViews(views: [view], revision: initial.revision), projectId: "project")
        let loaded = try await phone.savedViews(projectId: "project")
        XCTAssertEqual(loaded, saved)
        do {
            _ = try await phone.saveViews(initial, projectId: "project")
            XCTFail("Expected revision conflict")
        } catch { XCTAssertTrue(ProjectCloudService.isConflict(error)) }
        let legacy = try await api.savedViews(projectId: "legacy")
        XCTAssertNil(legacy)
    }
}
