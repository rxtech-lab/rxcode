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
            sourceSessionKey: "source-1",
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
        #expect(decoded.sourceSessionKey == "source-1")
        #expect(decoded.sortIndex == 4)
    }

    @Test("Status raw values are stable on the wire")
    func statusRawValues() {
        #expect(TaskStatus.pending.rawValue == "pending")
        #expect(TaskStatus.inProgress.rawValue == "in_progress")
        #expect(TaskStatus.pendingReview.rawValue == "pending_review")
        #expect(TaskStatus.done.rawValue == "done")
        #expect(TaskStatus.backlog.rawValue == "backlog")
    }

    // MARK: - Columns

    @Test("Status encodes as a bare string and keeps unknown ids")
    func statusCoding() throws {
        let data = try JSONEncoder().encode([TaskStatus.inProgress, TaskStatus(rawValue: "custom-qa")])
        #expect(String(data: data, encoding: .utf8) == #"["in_progress","custom-qa"]"#)
        let decoded = try JSONDecoder().decode([TaskStatus].self, from: data)
        #expect(decoded == [.inProgress, "custom-qa"])
    }

    @Test("A board written before columns existed gets the default columns")
    func legacyBoardGetsDefaultColumns() throws {
        let json = #"{"schemaVersion":1,"tasks":[{"title":"old","status":"pending_review"}]}"#
        let board = try JSONDecoder().decode(TaskBoard.self, from: Data(json.utf8))

        #expect(board.columns.isEmpty)
        #expect(board.effectiveColumns.map(\.id) == [.backlog, .pending, .inProgress, .pendingReview, .done])
        let inProgress = board.column(for: .inProgress)
        #expect(inProgress.triggersChat)
        #expect(inProgress.onSessionStop == .pendingReview)
        #expect(board.column(for: .pendingReview).onReviewFail == .inProgress)
        #expect(board.column(for: .done).countsAsDone)
        #expect(board.tasks(in: .pendingReview).map(\.title) == ["old"])
    }

    @Test("Columns round-trip with their triggers")
    func columnRoundTrip() throws {
        let column = TaskColumn(
            id: "qa", name: "QA", colorHex: "#12A594", systemImage: "testtube.2",
            triggersChat: true, countsAsDone: false,
            onSessionStop: .pendingReview, onReviewStart: "qa-running",
            onReviewPass: .done, onReviewFail: .inProgress
        )
        let data = try JSONEncoder().encode(TaskBoard(columns: [column]))
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: data)
        #expect(decoded.columns == [column])
    }

    @Test("A task whose column was deleted shows in the first column")
    func orphanedStatusFallsBack() {
        let task = ProjectTask(projectId: UUID(), title: "orphan", status: "deleted")
        let board = TaskBoard(tasks: [task])
        #expect(board.resolvedStatus(of: task) == .backlog)
        #expect(board.tasks(in: .backlog).map(\.title) == ["orphan"])
    }

    @Test("Trigger targets ignore missing columns and the column itself")
    func triggerTargets() {
        var columns = TaskColumn.defaults
        let review = columns.firstIndex { $0.id == .pendingReview }!
        columns[review].onReviewPass = "deleted"
        columns[review].onReviewStart = .pendingReview
        let task = ProjectTask(projectId: UUID(), title: "t", status: .pendingReview, sessionKey: "s")
        let board = TaskBoard(tasks: [task], columns: columns)

        #expect(board.triggerTarget(for: task, event: .reviewPass) == nil)
        #expect(board.triggerTarget(for: task, event: .reviewStart) == nil)
        #expect(board.triggerTarget(for: task, event: .reviewFail) == .inProgress)
        #expect(!board.isStatusLocked(task))
        #expect(board.isStatusLocked(ProjectTask(projectId: UUID(), title: "t", status: .inProgress, sessionKey: "s")))
        #expect(!board.isStatusLocked(ProjectTask(projectId: UUID(), title: "t", status: .inProgress)))
    }

    @Test("Dragging a column header onto another column takes its slot")
    func columnReorder() {
        let board = TaskBoard()
        #expect(board.effectiveColumns.map(\.id) == [.backlog, .pending, .inProgress, .pendingReview, .done])

        // Rightward: the dragged column lands where the target was and the
        // columns it passed shift left.
        #expect(board.columnOrder(moving: .backlog, to: .inProgress)
            == [.pending, .inProgress, .backlog, .pendingReview, .done])
        // Leftward: the target and everything after it shift right.
        #expect(board.columnOrder(moving: .done, to: .pending)
            == [.backlog, .done, .pending, .inProgress, .pendingReview])
        // No-ops the caller can skip.
        #expect(board.columnOrder(moving: .done, to: .done) == nil)
        #expect(board.columnOrder(moving: "deleted", to: .done) == nil)
        #expect(board.columnOrder(moving: .done, to: "deleted") == nil)
    }

    @Test("Dragging a view tab onto another tab takes its slot")
    func viewReorder() {
        let a = TaskSavedView(name: "A"), b = TaskSavedView(name: "B"), c = TaskSavedView(name: "C")
        let board = TaskBoard(savedViews: [a, b, c])

        #expect(board.viewOrder(moving: a.id, to: c.id)?.map(\.name) == ["B", "C", "A"])
        #expect(board.viewOrder(moving: c.id, to: a.id)?.map(\.name) == ["C", "A", "B"])
        #expect(board.viewOrder(moving: a.id, to: a.id) == nil)
        #expect(board.viewOrder(moving: UUID(), to: a.id) == nil)
        // A board with no saved views still has its implicit default tab.
        #expect(TaskBoard().viewOrder(moving: TaskSavedView.defaultViewId, to: UUID()) == nil)
    }

    @Test("Story progress and roll-up follow countsAsDone")
    func customDoneColumn() {
        let storyId = UUID()
        let story = ProjectStory(id: storyId, projectId: UUID(), title: "S")
        let columns = [
            TaskColumn(id: "todo", name: "Todo"),
            TaskColumn(id: "shipped", name: "Shipped", countsAsDone: true),
            TaskColumn(id: "archived", name: "Archived", countsAsDone: true),
        ]
        let board = TaskBoard(
            stories: [story],
            tasks: [
                ProjectTask(projectId: story.projectId, storyId: storyId, title: "a", status: "shipped"),
                ProjectTask(projectId: story.projectId, storyId: storyId, title: "b", status: "archived"),
            ],
            columns: columns
        )
        #expect(board.progress(for: story).done == 2)
        #expect(board.rolledUpStatus(for: story) == "shipped")
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
        let columns = TaskColumn.defaults
        #expect(reversed.visibleColumns(in: columns).map(\.id) == [.pending, .done])
        #expect(TaskSavedView(name: "All").visibleColumns(in: columns) == columns)
        // A view whose columns were all deleted falls back to the whole board.
        #expect(TaskSavedView(name: "Gone", statuses: ["deleted"]).visibleColumns(in: columns) == columns)
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

        #expect(board([]).rolledUpStatus(for: story) == .backlog)
        #expect(board([.pending, .pending]).rolledUpStatus(for: story) == .pending)
        #expect(board([.pending, .inProgress]).rolledUpStatus(for: story) == .inProgress)
        #expect(board([.done, .pendingReview]).rolledUpStatus(for: story) == .pendingReview)
        #expect(board([.done, .done]).rolledUpStatus(for: story) == .done)

        let progress = board([.done, .done, .inProgress]).progress(for: story)
        #expect(progress.done == 2)
        #expect(progress.total == 3)
        #expect(progress.percent == 67)
        #expect(progress.active == 1)
        #expect(board([]).progress(for: story).fraction == 0)

        let started = board([.pending, .inProgress, .pendingReview, .done]).progress(for: story)
        #expect(started.done == 1)
        #expect(started.active == 2)
        #expect(started.activeFraction == 0.5)
    }

    @Test("Task prompts parse back into title, body, fields and attachments")
    func taskPromptParsing() {
        var task = ProjectTask(projectId: UUID(), title: "Drag columns")
        task.details = "Should be able to drag.\n\nAnd drop."
        task.tags = ["dashboard", "ui"]
        let prompt = "[Attached image: /tmp/a.png]\n[Link: https://example.com]\n\n"
            + task.agentPrompt(storyTitle: "Dashboard", typeName: "Feature")

        let content = TaskPromptContent.parse(prompt)
        #expect(content.title == "Drag columns")
        #expect(content.body == "Should be able to drag.\n\nAnd drop.")
        #expect(content.fields.map(\.label) == ["Story", "Type", "Tags"])
        #expect(content.fields.last?.value == "dashboard, ui")
        #expect(content.references.map(\.kind) == [.image, .link])
        #expect(content.references.first?.value == "/tmp/a.png")

        let followUp = TaskPromptContent.parse("Please also add tests\n\n- a list")
        #expect(followUp.title == nil)
        #expect(followUp.body == "Please also add tests\n\n- a list")
        #expect(followUp.fields.isEmpty)
    }

    @Test("Only dispatched task messages resolve through task(in:)")
    func taskPromptDetection() {
        var task = ProjectTask(projectId: UUID(), title: "Parse task messages")
        task.details = "Render them like the Run tab."
        task.version = "v1.18.0"
        task.milestone = "v2"

        let prompt = task.agentPrompt(storyTitle: "Projects Dashboard", typeName: "Feature")
        let content = TaskPromptContent.task(in: prompt)
        #expect(content?.title == "Parse task messages")
        #expect(content?.fields.map(\.label) == ["Story", "Type", "Target version", "Milestone"])

        // Typed messages stay plain Markdown, even when they look list-like or
        // merely mention a task.
        #expect(TaskPromptContent.task(in: "Please also add tests\n\n- a list") == nil)
        #expect(TaskPromptContent.task(in: "The **Task:** label is not at the start") == nil)
    }

    @Test("Chat display extraction preserves a task message's structure")
    func taskPromptSurvivesDisplayExtraction() {
        var task = ProjectTask(projectId: UUID(), title: "Parse task messages")
        task.details = "Render them like the Run tab."
        task.tags = ["ui", "chat"]
        // The chat strips attachment markers before rendering; the task card has
        // to survive that pass, otherwise the bubble falls back to raw Markdown.
        let sent = "[Attached image: /tmp/shot.png]\n\n"
            + task.agentPrompt(storyTitle: "Projects Dashboard", typeName: "Feature")

        let displayed = ChatSession.extractDisplayedContent(from: sent)
        #expect(displayed.imagePaths == ["/tmp/shot.png"])

        let content = TaskPromptContent.task(in: displayed.text)
        #expect(content?.title == "Parse task messages")
        #expect(content?.body == "Render them like the Run tab.")
        #expect(content?.fields.map(\.label) == ["Story", "Type", "Tags"])
        #expect(content?.fields.last?.value == "ui, chat")
    }

    @Test("Stories match tag and version filters on their own fields")
    func storyViewMatching() {
        let story = ProjectStory(projectId: UUID(), title: "Epic")
        #expect(TaskSavedView(name: "All").matches(story, rolledUpStatus: .pending))
        #expect(!TaskSavedView(name: "UI", tags: ["ui"]).matches(story, rolledUpStatus: .pending))
        #expect(!TaskSavedView(name: "Done", statuses: [.done]).matches(story, rolledUpStatus: .pending))

        let tagged = ProjectStory(projectId: UUID(), title: "Epic", tags: ["ui"], version: "v2")
        #expect(TaskSavedView(name: "UI", tags: ["ui"]).matches(tagged, rolledUpStatus: .pending))
        #expect(TaskSavedView(name: "v2", version: "v2").matches(tagged, rolledUpStatus: .pending))
        #expect(!TaskSavedView(name: "v3", version: "v3").matches(tagged, rolledUpStatus: .pending))
    }

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

    @Test("The agent prompt carries type, priority and milestone")
    func agentPromptClassification() {
        let task = ProjectTask(projectId: UUID(), title: "Fix", milestone: "Beta", priority: .urgent)
        let prompt = task.agentPrompt(storyTitle: nil, typeName: "Bug")
        #expect(prompt.contains("- **Type:** Bug"))
        #expect(prompt.contains("- **Priority:** Urgent"))
        #expect(prompt.contains("- **Milestone:** Beta"))
    }

    @Test("A generated title is stripped of the decoration models add")
    func titleSuggestionParsing() {
        #expect(TaskTitleSuggestion.parse("Fix the crash on paste") == "Fix the crash on paste")
        #expect(TaskTitleSuggestion.parse("```\nTitle: \"Fix the crash on paste\".\n```") == "Fix the crash on paste")
        #expect(TaskTitleSuggestion.parse("\n\n- # Add a retry to RelayClient\n") == "Add a retry to RelayClient")
        #expect(TaskTitleSuggestion.parse("“修复粘贴时的崩溃。”") == "修复粘贴时的崩溃")
        #expect(TaskTitleSuggestion.parse("   \n ") == nil)

        // An ellipsis the writer meant is not a stray closing period.
        #expect(TaskTitleSuggestion.parse("Wait for the relay…") == "Wait for the relay…")
    }

    @Test("A title falls back to the description's first line, shortened")
    func titleSuggestionFallback() {
        #expect(TaskTitleSuggestion.fallback(from: "") == "")
        #expect(TaskTitleSuggestion.fallback(from: "\n\n  Fix login  \nmore detail") == "Fix login")
        #expect(TaskTitleSuggestion.fallback(from: "- Fix login") == "Fix login")

        let long = String(repeating: "word ", count: 40)
        let shortened = TaskTitleSuggestion.fallback(from: long)
        #expect(shortened.count <= TaskTitleSuggestion.maxLength + 1)
        #expect(shortened.hasSuffix("…"))
        #expect(!shortened.contains("  "))

        // No spaces to break on: cut where the limit lands.
        let cjk = String(repeating: "修", count: 100)
        #expect(TaskTitleSuggestion.truncate(cjk).count == TaskTitleSuggestion.maxLength + 1)
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
