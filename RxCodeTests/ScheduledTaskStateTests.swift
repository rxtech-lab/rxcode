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

    func testDueScheduledTasksFiresOnceWhenScheduleComesDue() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: hour, minute: minute, second: second))!
        }
        let task = ScheduledTask(name: "News", prompt: "Roundup", cronExpression: "0 7,19 * * *")
        var paused = ScheduledTask(name: "Paused", prompt: "Roundup", cronExpression: "0 7,19 * * *")
        paused.isEnabled = false
        appState.scheduledTasks = [task, paused]

        XCTAssertTrue(appState.dueScheduledTasks(since: at(18, 59, 40), now: at(18, 59, 59), calendar: calendar).isEmpty)
        XCTAssertEqual(appState.dueScheduledTasks(since: at(18, 59, 50), now: at(19, 0, 10), calendar: calendar).map(\.id), [task.id])
        XCTAssertTrue(appState.dueScheduledTasks(since: at(19, 0, 10), now: at(19, 0, 30), calendar: calendar).isEmpty)
        // A fire missed while the Mac slept runs once on wake.
        XCTAssertEqual(appState.dueScheduledTasks(since: at(18, 0, 0), now: at(21, 0, 0), calendar: calendar).map(\.id), [task.id])
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
