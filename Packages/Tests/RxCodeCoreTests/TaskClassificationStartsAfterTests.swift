import Foundation
import Testing
@testable import RxCodeCore

@Suite("Task classification starts-after")
struct TaskClassificationStartsAfterTests {
    @Test("Classification links a task to an existing task it starts after")
    func classificationStartsAfter() {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Search")
        let index = ProjectTask(projectId: projectId, storyId: story.id, title: "Index threads")
        let outside = ProjectTask(projectId: projectId, title: "Unrelated")
        let done = ProjectTask(projectId: projectId, storyId: story.id, title: "Old work", status: .done)
        let board = TaskBoard(stories: [story], tasks: [index, outside, done])

        var task = ProjectTask(projectId: projectId, storyId: story.id, title: "Add filters")
        let candidates = TaskClassification.startsAfterCandidates(for: task, board: board).map(\.title)
        #expect(candidates == ["Index threads"])

        let prompt = TaskClassification.prompt(
            title: task.title, details: "", storyTitle: story.title, board: board,
            startsAfterCandidates: candidates
        )
        #expect(prompt.contains(#""starts_after": string|null"#))
        #expect(prompt.contains(#"from ["Index threads"]"#))
        #expect(!TaskClassification.prompt(title: "t", details: "", storyTitle: nil, board: board).contains("starts_after"))

        let suggestion = TaskClassification.parse(#"{"starts_after": "index THREADS"}"#)
        suggestion?.apply(to: &task, board: board)
        #expect(task.parentTaskId == index.id)

        var unknown = ProjectTask(projectId: projectId, storyId: story.id, title: "t")
        TaskClassification(startsAfter: "Unrelated").apply(to: &unknown, board: board)
        #expect(unknown.parentTaskId == nil)

        var linked = ProjectTask(projectId: projectId, storyId: story.id, parentTaskId: outside.id, title: "t")
        suggestion?.apply(to: &linked, board: board)
        #expect(linked.parentTaskId == outside.id)

        // "Add filters" now starts after "Index threads", so offering it
        // back to "Index threads" would make a cycle.
        var linkedBoard = board
        linkedBoard.tasks.append(task)
        #expect(!TaskClassification.startsAfterCandidates(for: index, board: linkedBoard).contains { $0.id == task.id })
    }
}
