import Foundation
import XCTest
@testable import RxCodeMobile

/// Runs the real account-authenticated client over HTTP against the documented draft contract.
@MainActor
final class FlowcyDraftSimulationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1", "Requires the Flowcy Postman simulation.")
    }

    func testTaskAndStoryDraftsOverHTTP() async throws {
        var refreshes: [Bool] = []
        let service = ProjectCloudService(session: .shared, baseURL: URL(string: FlowcySimulation.baseURL)!) {
            refreshes.append($0)
            return $0 ? "simulation" : "expired"
        }
        let task = try await service.generateDraft(projectId: "project", kind: .task, prompt: "Cache the board")
        XCTAssertEqual(task.title, "Cache board data")
        XCTAssertTrue(task.details.contains("## Acceptance criteria"))
        let story = try await service.generateDraft(projectId: "project", kind: .story, prompt: "Enable offline use")
        XCTAssertEqual(story.title, "Enable offline work")
        XCTAssertEqual(refreshes, [false, true, false, true])
    }

    func testGenerationFailuresRemainErrors() async throws {
        let service = ProjectCloudService(session: .shared, baseURL: URL(string: FlowcySimulation.baseURL)!) { _ in "simulation" }
        for (project, prompt, status) in [("denied", "Do work", 404), ("project", "model failure", 502), ("project", " ", 400)] {
            do {
                _ = try await service.generateDraft(projectId: project, kind: .task, prompt: prompt)
                XCTFail("Expected generation to fail")
            } catch AutopilotService.ServiceError.apiError(let code, _) {
                XCTAssertEqual(code, status)
            }
        }
    }
}
