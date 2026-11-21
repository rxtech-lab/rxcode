import Foundation
import Testing
@testable import RxCodeCore

extension ProjectTaskTests {
    // MARK: - Classification fields

    @Test("Stories and tasks round trip their classification fields")
    func classificationRoundTrip() throws {
        let typeId = UUID()
        let story = ProjectStory(
            projectId: UUID(), title: "Epic", tags: ["ui"], version: "v1",
            milestone: "Beta", priority: .high, typeId: typeId
        )
        let task = ProjectTask(
            projectId: UUID(), title: "t", milestone: "Beta", priority: .urgent, typeId: typeId
        )
        let board = TaskBoard(
            stories: [story], tasks: [task],
            labels: [TaskLabel(name: "ui", colorHex: "#FF0000")],
            itemTypes: [TaskItemType(id: typeId, name: "Spike", colorHex: "#00FF00")]
        )
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.stories == [story])
        #expect(decoded.tasks == [task])
        #expect(decoded.labelColorHex(for: "ui") == "#FF0000")
        #expect(decoded.itemType(id: typeId)?.name == "Spike")
    }

    @Test("Boards written before classification fields still decode")
    func legacyBoardDecodes() throws {
        let json = #"{"stories":[{"id":"\#(UUID().uuidString)","projectId":"\#(UUID().uuidString)","title":"Old"}],"tasks":[{"title":"t","priority":"bogus"}]}"#
        let board = try JSONDecoder().decode(TaskBoard.self, from: Data(json.utf8))
        #expect(board.stories.first?.tags == [])
        #expect(board.stories.first?.priority == nil)
        #expect(board.tasks.first?.priority == nil)
        #expect(board.labels.isEmpty)
        #expect(board.effectiveTypes == TaskItemType.defaults)
    }

    @Test("Board facets include story tags, labels and milestones")
    func boardFacetsIncludeStories() {
        let projectId = UUID()
        let board = TaskBoard(
            stories: [ProjectStory(projectId: projectId, title: "s", tags: ["epic"], version: "v3", milestone: "GA")],
            tasks: [ProjectTask(projectId: projectId, title: "t", tags: ["ui"], milestone: "Beta")],
            labels: [TaskLabel(name: "unused")]
        )
        #expect(board.allTags == ["epic", "ui", "unused"])
        #expect(board.allVersions == ["v3"])
        #expect(board.allMilestones == ["Beta", "GA"])
    }

    @Test("Classification parses JSON wrapped in prose")
    func classificationParsing() {
        let raw = """
        Sure! ```json
        {"type": "Bug", "priority": "HIGH", "tags": ["ui"], "version": null, "milestone": "Beta"}
        ```
        """
        let parsed = TaskClassification.parse(raw)
        #expect(parsed?.type == "Bug")
        #expect(parsed?.priority == "HIGH")
        #expect(parsed?.milestone == "Beta")
        #expect(TaskClassification.parse("no json here") == nil)

        // One odd value must not discard the rest of the suggestion.
        let loose = TaskClassification.parse(#"{"type": "Bug", "priority": "P1", "tags": "ui", "version": 2, "milestone": "Beta"}"#)
        #expect(loose?.version == "2")
        #expect(loose?.tags == ["ui"])
        #expect(loose?.milestone == "Beta")
        var task = ProjectTask(projectId: UUID(), title: "t")
        loose?.apply(to: &task, board: TaskBoard())
        #expect(task.priority == .high)
        #expect(task.version == "2")
    }

    @Test("Classification prompt asks for priority, version and milestone whenever the board has them")
    func classificationPromptFillsProperties() {
        let board = TaskBoard(tasks: [ProjectTask(projectId: UUID(), title: "x", version: "v2", milestone: "Beta")])
        let prompt = TaskClassification.prompt(title: "Fix", details: "", storyTitle: nil, board: board)
        #expect(prompt.contains("priority: always one of"))
        #expect(prompt.contains("for new work use the newest, v2. Never null."))
        #expect(prompt.contains("existing milestone from [Beta]. Never null."))

        let empty = TaskClassification.prompt(title: "Fix", details: "", storyTitle: nil, board: TaskBoard())
        #expect(empty.contains("even if new. Otherwise null."))
        #expect(!empty.contains("\"story\""))
    }

    @Test("Classification picks a parent story only for a task without one")
    func classificationStory() {
        let projectId = UUID()
        let parent = ProjectStory(projectId: projectId, title: "Projects Dashboard", version: "v3", milestone: "GA")
        let board = TaskBoard(stories: [parent])

        let prompt = TaskClassification.prompt(title: "Fix", details: "", storyTitle: nil, board: board)
        #expect(prompt.contains(#""story": string|null"#))
        #expect(prompt.contains(#"from ["Projects Dashboard"]"#))
        #expect(!TaskClassification.prompt(title: "Fix", details: "", storyTitle: "Projects Dashboard", board: board).contains("- story:"))
        #expect(!TaskClassification.prompt(title: "Fix", details: "", storyTitle: nil, board: board, isStory: true).contains("- story:"))

        let suggestion = TaskClassification.parse(#"{"story": "projects dashboard", "version": "v9"}"#)
        var task = ProjectTask(projectId: projectId, title: "t")
        suggestion?.apply(to: &task, board: board)
        #expect(task.storyId == parent.id)
        #expect(task.version == "v3")
        #expect(task.milestone == "GA")

        var unknown = ProjectTask(projectId: projectId, title: "t")
        TaskClassification(story: "Nope").apply(to: &unknown, board: board)
        #expect(unknown.storyId == nil)

        let other = UUID()
        var chosen = ProjectTask(projectId: projectId, storyId: other, title: "t")
        suggestion?.apply(to: &chosen, board: board)
        #expect(chosen.storyId == other)
    }

    @Test("Classification only fills empty fields and reuses board spelling")
    func classificationApply() {
        let board = TaskBoard(tasks: [ProjectTask(projectId: UUID(), title: "x", tags: ["UI"])])
        let suggestion = TaskClassification(
            type: "bug", priority: "High", tags: ["ui", "perf", "a", "b"],
            version: "v9", milestone: "null"
        )

        var blank = ProjectTask(projectId: UUID(), title: "t")
        suggestion.apply(to: &blank, board: board)
        #expect(blank.typeId == TaskItemType.defaults[1].id)
        #expect(blank.priority == .high)
        #expect(blank.tags == ["UI", "perf", "a"])
        #expect(blank.version == "v9")
        #expect(blank.milestone == nil)

        var preset = ProjectTask(projectId: UUID(), title: "t", version: "v1", priority: .low)
        suggestion.apply(to: &preset, board: board)
        #expect(preset.version == "v1")
        #expect(preset.priority == .low)

        var unknownType = ProjectTask(projectId: UUID(), title: "t")
        TaskClassification(type: "Epic").apply(to: &unknownType, board: board)
        #expect(unknownType.typeId == nil)
    }

    @Test("Classification fills story version and milestone without replacing choices")
    func storyClassificationApply() {
        let board = TaskBoard()
        let suggestion = TaskClassification(
            type: "Feature", priority: "medium", tags: ["ui"],
            version: "v1.18.0", milestone: "v2"
        )
        var story = ProjectStory(projectId: UUID(), title: "Projects Dashboard")
        suggestion.apply(to: &story, board: board)
        #expect(story.version == "v1.18.0")
        #expect(story.milestone == "v2")
        #expect(story.priority == .medium)

        story.version = "v1.19.0"
        story.milestone = "v3"
        suggestion.apply(to: &story, board: board)
        #expect(story.version == "v1.19.0")
        #expect(story.milestone == "v3")

        let prompt = TaskClassification.prompt(
            title: story.title, details: "Target version v1.18.0; milestone v2",
            storyTitle: nil, board: board, isStory: true
        )
        #expect(prompt.contains("Story title: Projects Dashboard"))
        #expect(prompt.contains("version explicitly stated"))
    }

    @Test("A linked story decodes tolerantly and mirrors onto another board")
    func linkedStoryMirroring() throws {
        let owner = UUID(), other = UUID(), third = UUID()
        let legacy = #"{"id":"\#(UUID().uuidString)","projectId":"\#(owner.uuidString)","title":"Old"}"#
        let decoded = try JSONDecoder().decode(ProjectStory.self, from: Data(legacy.utf8))
        #expect(decoded.linkedProjectIds.isEmpty)
        #expect(decoded.projectGroup == [owner])

        let typeId = UUID()
        let story = ProjectStory(projectId: owner, title: "Shared", version: "v2", typeId: typeId, linkedProjectIds: [owner, other])
        #expect(story.linkedProjectIds == [other])

        let copy = story.mirrored(into: other, group: [owner, other, third], typeId: nil)
        #expect(copy.id == story.id)
        #expect(copy.projectId == other)
        #expect(copy.linkedProjectIds == [owner, third])
        #expect(copy.typeId == nil)
        #expect(copy.version == "v2")
        #expect(copy.projectGroup == [other, owner, third])

        let roundTrip = try JSONDecoder().decode(ProjectStory.self, from: JSONEncoder().encode(copy))
        #expect(roundTrip.linkedProjectIds == [owner, third])
    }

    @Test("The agent prompt carries type, priority and milestone")
    func agentPromptClassification() {
        let task = ProjectTask(projectId: UUID(), title: "Fix", milestone: "Beta", priority: .urgent)
        let prompt = task.agentPrompt(storyTitle: nil, typeName: "Bug")
        #expect(prompt.contains("- **Type:** Bug"))
        #expect(prompt.contains("- **Priority:** Urgent"))
        #expect(prompt.contains("- **Milestone:** Beta"))
    }
}
