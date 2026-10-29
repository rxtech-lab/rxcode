import Foundation
import Testing
@testable import RxCodeCore

@Suite("Task classification schedule")
struct TaskClassificationScheduleTests {
    @Test("AI schedule fills task and story drafts")
    func fillsSchedule() throws {
        let suggestion = try #require(TaskClassification.parse("""
        {"deadline":"2026-11-06T18:00:00+08:00","size":" L ","delays":["Waiting for API access", " "]}
        """))
        let board = TaskBoard()
        var task = ProjectTask(projectId: UUID(), title: "Implement search")
        var story = ProjectStory(projectId: task.projectId, title: "Search")
        suggestion.apply(to: &task, board: board)
        suggestion.apply(to: &story, board: board)
        let expected = ISO8601DateFormatter().date(from: "2026-11-06T10:00:00Z")
        #expect(task.deadline == expected)
        #expect(story.deadline == expected)
        #expect(task.size == .l)
        #expect(story.size == .l)
        #expect(task.delays.map(\.reason) == ["Waiting for API access"])
        #expect(story.delays.map(\.reason) == task.delays.map(\.reason))
        #expect(task.delays.first?.author == nil)
    }

    @Test("Existing schedule values survive AI suggestions and repeated application")
    func preservesSchedule() {
        var task = ProjectTask(projectId: UUID(), title: "Search")
        task.deadline = Date(timeIntervalSince1970: 1_800_000_000)
        task.size = .s
        task.delays = [TaskDelay(reason: "User reason")]
        var story = ProjectStory(projectId: task.projectId, title: "Search")
        story.deadline = task.deadline
        story.size = task.size
        story.delays = task.delays
        let originalTask = task
        let originalStory = story
        let suggestion = TaskClassification(deadline: "2026-12-01T18:00:00Z", size: "xl", delays: ["AI reason"])
        for _ in 0..<2 {
            suggestion.apply(to: &task, board: TaskBoard())
            suggestion.apply(to: &story, board: TaskBoard())
        }
        #expect(task == originalTask)
        #expect(story == originalStory)
    }

    @Test("Malformed schedule fields do not discard other suggestions")
    func toleratesMalformedSchedule() throws {
        let suggestion = try #require(TaskClassification.parse(#"{"priority":"high","size":[],"deadline":{},"delays":false}"#))
        var task = ProjectTask(projectId: UUID(), title: "Search")
        suggestion.apply(to: &task, board: TaskBoard())
        #expect(task.priority == .high)
        #expect(task.deadline == nil)
        #expect(task.size == nil)
        #expect(task.delays.isEmpty)
        TaskClassification(deadline: "tomorrow", size: "huge").apply(to: &task, board: TaskBoard())
        #expect(task.deadline == nil)
        #expect(task.size == nil)
    }

    @Test("Legacy responses and fractional ISO dates remain supported")
    func compatibility() throws {
        var task = ProjectTask(projectId: UUID(), title: "Search")
        let legacy = try #require(TaskClassification.parse(#"{"priority":"medium"}"#))
        legacy.apply(to: &task, board: TaskBoard())
        #expect(task.size == nil)
        #expect(task.deadline == nil)
        let suggestion = try #require(TaskClassification.parse(#"{"deadline":"2026-11-06T18:00:00.123Z","size":"xs","delays":"Access blocked"}"#))
        suggestion.apply(to: &task, board: TaskBoard())
        #expect(task.deadline != nil)
        #expect(task.size == .xs)
        #expect(task.delays.map(\.reason) == ["Access blocked"])
        let delayIDs = task.delays.map(\.id)
        suggestion.apply(to: &task, board: TaskBoard())
        #expect(task.delays.map(\.id) == delayIDs)
    }

    @Test("Task and story prompts request grounded schedule data with a date reference")
    func schedulePrompt() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T14:00:00Z"))
        let zone = try #require(TimeZone(identifier: "Asia/Hong_Kong"))
        for isStory in [false, true] {
            let prompt = TaskClassification.prompt(
                title: "Search", details: "Due next Friday", storyTitle: nil,
                board: TaskBoard(), isStory: isStory, now: now, timeZone: zone
            )
            #expect(prompt.contains(#""deadline": string|null"#))
            #expect(prompt.contains(#""size": string|null"#))
            #expect(prompt.contains(#""delays": [string]"#))
            #expect(prompt.contains("2026-10-28T22:00:00+08:00"))
            #expect(prompt.contains("Asia/Hong_Kong"))
            #expect(prompt.contains("never invent delay history"))
        }
    }
}
