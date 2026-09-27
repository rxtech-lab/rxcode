import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ScheduledTaskStateTests: XCTestCase {

    private var persistence: MockAppStatePersistence!
    private var appState: AppState!

    override func setUp() async throws {
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
    }

    override func tearDown() async throws {
        appState = nil
        persistence = nil
    }

    func testScheduledTaskLifecyclePersists() async throws {
        let projectId = UUID()
        var task = ScheduledTask(projectId: projectId, name: "Nightly", prompt: "Run tests", cronExpression: "@daily")

        appState.upsertScheduledTask(task)
        task.name = "Nightly tests"
        appState.upsertScheduledTask(task)
        appState.setScheduledTaskEnabled(id: task.id, false)

        XCTAssertEqual(appState.scheduledTasks.map(\.name), ["Nightly tests"])
        XCTAssertEqual(appState.scheduledTasks.first?.isEnabled, false)
        let persisted = try await waitForPersistedScheduledTasks { $0.first?.isEnabled == false }
        XCTAssertEqual(persisted.map(\.name), ["Nightly tests"])

        appState.scheduledTasks = []
        await appState.loadScheduledTasksFromDisk()
        XCTAssertEqual(appState.scheduledTasks.map(\.id), [task.id])

        appState.deleteScheduledTasks(projectId: projectId)
        XCTAssertTrue(appState.scheduledTasks.isEmpty)
        _ = try await waitForPersistedScheduledTasks { $0.isEmpty }
    }

    /// Scheduled-task saves run on a detached `Task`; waits for the mock to
    /// hold a list satisfying `condition`.
    private func waitForPersistedScheduledTasks(
        _ condition: ([ScheduledTask]) -> Bool
    ) async throws -> [ScheduledTask] {
        for _ in 0..<100 {
            let tasks = await persistence.loadScheduledTasks()
            if condition(tasks) { return tasks }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scheduled tasks were not persisted")
        return await persistence.loadScheduledTasks()
    }
}
