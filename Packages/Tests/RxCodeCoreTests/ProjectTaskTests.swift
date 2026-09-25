import Foundation
import Testing
@testable import RxCodeCore

@Suite("Project task board")
struct ProjectTaskTests {

    // MARK: - Round trip

    @Test("ProjectTask round trips every field")
    func taskRoundTrip() throws {
        let projectId = UUID()
        let storyId = UUID()
        let task = ProjectTask(
            projectId: projectId,
            storyId: storyId,
            title: "Wire the board",
            details: "Columns plus drag and drop",
            status: .pendingReview,
            version: "v1.3.0",
            tags: ["ui", "board"],
            agent: TaskAgentConfig(
                provider: .codex,
                model: "gpt-5.4",
                effort: "high",
                permissionMode: .acceptEdits,
                planMode: true
            ),
            sessionKey: "sess-1",
            sortIndex: 4
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ProjectTask.self, from: try encoder.encode(task))

        #expect(decoded.id == task.id)
        #expect(decoded.projectId == projectId)
        #expect(decoded.storyId == storyId)
        #expect(decoded.title == "Wire the board")
        #expect(decoded.status == .pendingReview)
        #expect(decoded.version == "v1.3.0")
        #expect(decoded.tags == ["ui", "board"])
        #expect(decoded.agent.provider == .codex)
        #expect(decoded.agent.model == "gpt-5.4")
        #expect(decoded.agent.effort == "high")
        #expect(decoded.agent.permissionMode == .acceptEdits)
        #expect(decoded.agent.planMode)
        #expect(decoded.sessionKey == "sess-1")
        #expect(decoded.sortIndex == 4)
    }

    @Test("Status raw values are stable on the wire")
    func statusRawValues() {
        #expect(TaskStatus.pending.rawValue == "pending")
        #expect(TaskStatus.inProgress.rawValue == "in_progress")
        #expect(TaskStatus.pendingReview.rawValue == "pending_review")
        #expect(TaskStatus.done.rawValue == "done")
    }

    // MARK: - Tolerant decoding

    @Test("A task payload missing newer fields still decodes")
    func tolerantTaskDecoding() throws {
        let json = """
        {"id":"\(UUID().uuidString)","projectId":"\(UUID().uuidString)","title":"Old task"}
        """
        let decoded = try JSONDecoder().decode(ProjectTask.self, from: Data(json.utf8))

        #expect(decoded.title == "Old task")
        #expect(decoded.status == .pending)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.attachments.isEmpty)
        #expect(decoded.version == nil)
        #expect(decoded.sessionKey == nil)
        #expect(decoded.agent.planMode == false)
        #expect(decoded.sortIndex == 0)
    }

    @Test("An empty board payload decodes to an empty board")
    func tolerantBoardDecoding() throws {
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: Data("{}".utf8))

        #expect(decoded.tasks.isEmpty)
        #expect(decoded.stories.isEmpty)
        #expect(decoded.savedViews.isEmpty)
        #expect(decoded.schemaVersion == TaskBoard.currentSchemaVersion)
    }

    // MARK: - Columns and ordering

    @Test("Tasks in a column come back in sort order")
    func columnOrdering() {
        let projectId = UUID()
        let board = TaskBoard(tasks: [
            ProjectTask(projectId: projectId, title: "third", status: .pending, sortIndex: 3),
            ProjectTask(projectId: projectId, title: "first", status: .pending, sortIndex: 1),
            ProjectTask(projectId: projectId, title: "other column", status: .done, sortIndex: 2),
            ProjectTask(projectId: projectId, title: "second", status: .pending, sortIndex: 2),
        ])

        #expect(board.tasks(in: .pending).map(\.title) == ["first", "second", "third"])
        #expect(board.tasks(in: .done).map(\.title) == ["other column"])
        #expect(board.tasks(in: .inProgress).isEmpty)
    }

    @Test("Append places a task after the current last card")
    func appendSortIndex() {
        let projectId = UUID()
        let board = TaskBoard(tasks: [
            ProjectTask(projectId: projectId, title: "a", status: .pending, sortIndex: 1),
            ProjectTask(projectId: projectId, title: "b", status: .pending, sortIndex: 7),
        ])

        #expect(board.appendSortIndex(for: .pending) == 8)
        // An empty column starts at 1 so the first card is never index 0, which
        // `upsertTask` treats as "unset".
        #expect(board.appendSortIndex(for: .done) == 1)
    }

    @Test("Dropping between two cards takes the midpoint")
    func midpointSortIndex() {
        let projectId = UUID()
        let a = ProjectTask(projectId: projectId, title: "a", sortIndex: 2)
        let b = ProjectTask(projectId: projectId, title: "b", sortIndex: 3)
        let column = [a, b]

        #expect(TaskBoard.sortIndex(between: a, and: b, in: column) == 2.5)
        #expect(TaskBoard.sortIndex(between: a, and: nil, in: column) == 3)
        #expect(TaskBoard.sortIndex(between: nil, and: b, in: column) == 2)
        #expect(TaskBoard.sortIndex(between: nil, and: nil, in: []) == 0)
    }

    // MARK: - Saved views

    @Test("A saved view matches on every tag plus the version")
    func savedViewFiltering() {
        let projectId = UUID()
        let uiRelease = ProjectTask(projectId: projectId, title: "ui", version: "v1.0", tags: ["ui", "board"])
        let uiOther = ProjectTask(projectId: projectId, title: "ui next", version: "v2.0", tags: ["ui"])
        let backend = ProjectTask(projectId: projectId, title: "backend", version: "v1.0", tags: ["api"])

        let view = TaskSavedView(name: "UI v1", tags: ["ui"], version: "v1.0")
        #expect(view.matches(uiRelease))
        #expect(!view.matches(uiOther))
        #expect(!view.matches(backend))

        // Every tag must be present, not just one.
        let strict = TaskSavedView(name: "Board UI", tags: ["ui", "board"])
        #expect(strict.matches(uiRelease))
        #expect(!strict.matches(uiOther))

        // An unconstrained view is treated as "no filter".
        let empty = TaskSavedView(name: "All")
        #expect(empty.isEmpty)
        #expect(empty.matches(backend))
    }

    @Test("Board surfaces its distinct tags and versions")
    func boardFacets() {
        let projectId = UUID()
        let board = TaskBoard(tasks: [
            ProjectTask(projectId: projectId, title: "a", version: "v1.0", tags: ["ui", "board"]),
            ProjectTask(projectId: projectId, title: "b", version: "v2.0", tags: ["ui"]),
            ProjectTask(projectId: projectId, title: "c", version: nil, tags: []),
        ])

        #expect(board.allTags == ["board", "ui"])
        #expect(board.allVersions == ["v2.0", "v1.0"])
    }

    // MARK: - Assignment and prompt

    @Test("A task counts as assigned once a provider or model is set")
    func assignmentDetection() {
        #expect(!TaskAgentConfig().isAssigned)
        #expect(TaskAgentConfig(provider: .claudeCode).isAssigned)
        #expect(TaskAgentConfig(model: "opus").isAssigned)
        // Plan mode alone is not an assignment — there is no agent to run.
        #expect(!TaskAgentConfig(planMode: true).isAssigned)
    }

    @Test("The agent prompt carries story, version, tags and details")
    func agentPrompt() {
        let task = ProjectTask(
            projectId: UUID(),
            title: "Add the board",
            details: "Four columns.",
            version: "v1.3.0",
            tags: ["ui"]
        )

        let prompt = task.agentPrompt(storyTitle: "Task management")
        // Markdown blocks separated by blank lines, so the chat bubble doesn't
        // collapse them into one line.
        #expect(prompt == """
        **Task:** Add the board

        Four columns.

        - **Story:** Task management
        - **Tags:** ui
        - **Target version:** v1.3.0
        """)

        // No story, no empty "Story:" line; no context at all, no list.
        #expect(!task.agentPrompt(storyTitle: nil).contains("Story:"))
        let bare = ProjectTask(projectId: UUID(), title: "Just do it")
        #expect(bare.agentPrompt(storyTitle: nil) == "**Task:** Just do it")
    }

    // MARK: - Attachments

    @Test("Task board attachments persist by path, not inlined bytes")
    func attachmentStripsInlineData() {
        let withData = Attachment(
            type: .image,
            name: "shot.png",
            path: "/tmp/shot.png",
            fileSize: 12,
            imageData: Data([0x1, 0x2, 0x3])
        )
        let stripped = withData.persistableInTaskBoard()

        #expect(stripped.imageData == nil)
        #expect(stripped.path == "/tmp/shot.png")
        #expect(stripped.name == "shot.png")

        // A clipboard image has no path yet, so its bytes must be kept or the
        // image would be lost before `resolvingClipboardImages` runs.
        let clipboard = Attachment(type: .image, name: "pasted.png", imageData: Data([0x9]))
        #expect(clipboard.persistableInTaskBoard().imageData != nil)
    }

    // MARK: - Stories

    @Test("Board resolves a task's parent story")
    func storyLookup() {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Task management")
        let board = TaskBoard(
            stories: [story],
            tasks: [ProjectTask(projectId: projectId, storyId: story.id, title: "a")]
        )

        #expect(board.story(id: story.id)?.title == "Task management")
        #expect(board.story(id: nil) == nil)
        #expect(board.story(id: UUID()) == nil)
    }

    // MARK: - Views

    @Test("A saved view filters by story and visible statuses")
    func savedViewStoryAndStatus() {
        let projectId = UUID()
        let storyId = UUID()
        let inStory = ProjectTask(projectId: projectId, storyId: storyId, title: "a", status: .inProgress)
        let loose = ProjectTask(projectId: projectId, title: "b", status: .pending)

        let storyView = TaskSavedView(name: "Story", storyId: storyId)
        #expect(storyView.matches(inStory))
        #expect(!storyView.matches(loose))

        let active = TaskSavedView(name: "Active", statuses: [.inProgress, .pendingReview])
        #expect(active.matches(inStory))
        #expect(!active.matches(loose))
        // Columns keep board order regardless of the order they were picked in.
        let reversed = TaskSavedView(name: "R", statuses: [.done, .pending])
        #expect(reversed.visibleStatuses == [.pending, .done])
        #expect(TaskSavedView(name: "All").visibleStatuses == TaskStatus.allCases)
    }

    @Test("A view written before layouts existed decodes as an unfiltered board")
    func savedViewLegacyDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"UI","tags":["ui"]}"#
        let view = try JSONDecoder().decode(TaskSavedView.self, from: Data(json.utf8))
        #expect(view.name == "UI")
        #expect(view.layout == .board)
        #expect(view.tags == ["ui"])
        #expect(view.storyId == nil)
        #expect(view.statuses.isEmpty)
    }

    @Test("A board with no saved views exposes the implicit default view")
    func effectiveViews() {
        #expect(TaskBoard().effectiveViews.map(\.id) == [TaskSavedView.defaultViewId])
        let custom = TaskSavedView(name: "Table", layout: .table)
        #expect(TaskBoard(savedViews: [custom]).effectiveViews == [custom])
    }

    @Test("Stories roll up progress and a column from their tasks")
    func storyRollUp() {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Epic")
        func board(_ statuses: [TaskStatus]) -> TaskBoard {
            TaskBoard(
                stories: [story],
                tasks: statuses.map { ProjectTask(projectId: projectId, storyId: story.id, title: "t", status: $0) }
            )
        }

        #expect(board([]).rolledUpStatus(for: story) == .pending)
        #expect(board([.pending, .pending]).rolledUpStatus(for: story) == .pending)
        #expect(board([.pending, .inProgress]).rolledUpStatus(for: story) == .inProgress)
        #expect(board([.done, .pendingReview]).rolledUpStatus(for: story) == .pendingReview)
        #expect(board([.done, .done]).rolledUpStatus(for: story) == .done)

        let progress = board([.done, .done, .inProgress]).progress(for: story)
        #expect(progress.done == 2)
        #expect(progress.total == 3)
        #expect(progress.percent == 67)
        #expect(board([]).progress(for: story).fraction == 0)
    }

    @Test("Stories are hidden by tag and version filters")
    func storyViewMatching() {
        let story = ProjectStory(projectId: UUID(), title: "Epic")
        #expect(TaskSavedView(name: "All").matches(story, rolledUpStatus: .pending))
        #expect(!TaskSavedView(name: "UI", tags: ["ui"]).matches(story, rolledUpStatus: .pending))
        #expect(!TaskSavedView(name: "Done", statuses: [.done]).matches(story, rolledUpStatus: .pending))
    }

    @Test("Keyword search covers title, details, tags and version")
    func keywordMatching() {
        let task = ProjectTask(projectId: UUID(), title: "Order routing", details: "OMS work", version: "v2", tags: ["backend"])
        #expect(task.matches(keyword: ""))
        #expect(task.matches(keyword: "ROUTING"))
        #expect(task.matches(keyword: "oms"))
        #expect(task.matches(keyword: "backend"))
        #expect(task.matches(keyword: "v2"))
        #expect(!task.matches(keyword: "frontend"))
    }
}
