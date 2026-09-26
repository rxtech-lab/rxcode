import Foundation
import Testing
@testable import RxCodeCore

@Suite("Project cloud sync")
struct ProjectCloudSyncTests {

    // MARK: - Merge decisions

    @Test("Three-way merge picks the side that changed")
    func mergeDecisions() {
        let base = CloudStoryFields(title: "A")
        let changed = CloudStoryFields(title: "B")
        let other = CloudStoryFields(title: "C")

        #expect(CloudMergeDecision.decide(local: base, base: base, remote: base, localIsNewer: false) == .inSync)
        #expect(CloudMergeDecision.decide(local: changed, base: base, remote: changed, localIsNewer: false) == .inSync)
        #expect(CloudMergeDecision.decide(local: changed, base: base, remote: base, localIsNewer: false) == .push)
        #expect(CloudMergeDecision.decide(local: base, base: base, remote: changed, localIsNewer: true) == .pull)
        #expect(CloudMergeDecision.decide(local: changed, base: base, remote: other, localIsNewer: true) == .push)
        #expect(CloudMergeDecision.decide(local: changed, base: base, remote: other, localIsNewer: false) == .pull)
    }

    // MARK: - Normalization

    @Test("Fields normalize like Autopilot's validation")
    func normalization() {
        let fields = CloudTaskFields(
            title: "  Ship it  ",
            status: "custom-123",
            priority: "whenever",
            type: "  ",
            tags: [" ui ", "ui", "", "api"],
            version: ""
        )
        #expect(fields.title == "Ship it")
        #expect(fields.status == "backlog")
        #expect(fields.priority == nil)
        #expect(fields.type == nil)
        #expect(fields.tags == ["ui", "api"])
        #expect(fields.version == nil)
    }

    @Test("Nil fields encode as null so a PATCH clears them")
    func encodesNulls() throws {
        let data = try JSONEncoder().encode(CloudTaskFields(title: "T"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] is NSNull)
        #expect(json["storyId"] is NSNull)
        #expect(json["priority"] is NSNull)
    }

    // MARK: - Decoding

    @Test("Remote board decodes Autopilot's JSON")
    func decodesRemoteBoard() throws {
        let json = """
        {
          "stories": [{
            "id": "s1", "docsRepositoryId": "r1", "title": "Story", "details": "",
            "tags": "[\\"a\\"]", "version": null, "milestone": null, "priority": "high",
            "type": "Feature", "createdAt": "2026-09-26T10:00:00.000Z",
            "updatedAt": "2026-09-26T10:00:00.000Z", "progress": { "done": 0, "total": 1 }
          }],
          "tasks": [{
            "id": "t1", "docsRepositoryId": "r1", "storyId": "s1", "parentTaskId": null,
            "title": "Task", "details": "Body", "status": "in_progress", "priority": null,
            "type": null, "tags": ["x"], "version": "v1", "milestone": null,
            "sortIndex": 2.5, "createdAt": "2026-09-26T10:00:00Z", "updatedAt": "2026-09-26T11:00:00Z"
          }]
        }
        """
        let board = try JSONDecoder().decode(CloudRemoteBoard.self, from: Data(json.utf8))
        let story = try #require(board.stories.first)
        #expect(story.id == "s1")
        #expect(story.fields.tags == ["a"])
        #expect(story.fields.priority == "high")
        #expect(story.updatedAt != nil)

        let task = try #require(board.tasks.first)
        #expect(task.fields.status == "in_progress")
        #expect(task.fields.storyId == "s1")
        #expect(task.fields.sortIndex == 2.5)
        #expect(task.fields.version == "v1")
        #expect(task.updatedAt != nil)
    }

    // MARK: - Board mapping

    @Test("Local tasks map to cloud fields through the id links")
    func localToCloud() {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Story")
        let parent = ProjectTask(projectId: projectId, title: "Parent")
        let type = TaskItemType.defaults[0]
        let task = ProjectTask(
            projectId: projectId,
            storyId: story.id,
            parentTaskId: parent.id,
            title: "Child",
            status: .pendingReview,
            priority: .urgent,
            typeId: type.id,
            sortIndex: 3
        )
        let board = TaskBoard(stories: [story], tasks: [parent, task])
        let sync = CloudBoardSyncState(
            stories: [story.id: CloudItemLink(remoteId: "rs", base: CloudStoryFields(title: "Story"))],
            tasks: [parent.id: CloudItemLink(remoteId: "rp", base: CloudTaskFields(title: "Parent"))]
        )

        let fields = board.cloudFields(for: task, sync: sync)
        #expect(fields.storyId == "rs")
        #expect(fields.parentTaskId == "rp")
        #expect(fields.status == "pending_review")
        #expect(fields.priority == "urgent")
        #expect(fields.type == type.name)
        #expect(fields.sortIndex == 3)
    }

    @Test("Custom columns map to the nearest Autopilot status and survive a round trip")
    func customColumns() {
        let shipped = TaskColumn(id: .custom(), name: "Shipped", countsAsDone: true)
        let board = TaskBoard(columns: TaskColumn.defaults + [shipped])
        #expect(board.cloudStatus(for: shipped.id) == "done")
        // Unchanged remote status keeps the custom column.
        #expect(board.localStatus(forCloud: "done", current: shipped.id) == shipped.id)
        // A different remote status moves to the matching built-in column.
        #expect(board.localStatus(forCloud: "pending", current: shipped.id) == .pending)
    }

    @Test("Pulled fields resolve remote ids back to local ids")
    func cloudToLocal() {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Story")
        let parent = ProjectTask(projectId: projectId, title: "Parent")
        let task = ProjectTask(projectId: projectId, title: "Old", agent: TaskAgentConfig(provider: .claudeCode))
        let board = TaskBoard(stories: [story], tasks: [parent, task])
        let sync = CloudBoardSyncState(
            stories: [story.id: CloudItemLink(remoteId: "rs", base: CloudStoryFields(title: "Story"))],
            tasks: [parent.id: CloudItemLink(remoteId: "rp", base: CloudTaskFields(title: "Parent"))]
        )
        let remote = CloudTaskFields(
            title: "New",
            status: "done",
            priority: "low",
            tags: ["t"],
            storyId: "rs",
            parentTaskId: "rp",
            sortIndex: 7
        )

        let pulled = board.applying(remote, to: task, sync: sync, updatedAt: nil)
        #expect(pulled.title == "New")
        #expect(pulled.status == .done)
        #expect(pulled.priority == .low)
        #expect(pulled.storyId == story.id)
        #expect(pulled.parentTaskId == parent.id)
        #expect(pulled.sortIndex == 7)
        // Device-local settings are untouched.
        #expect(pulled.agent.provider == .claudeCode)
        // And the pulled task maps back to exactly what the cloud sent.
        #expect(board.cloudFields(for: pulled, sync: sync) == remote)
    }

    // MARK: - Persistence

    @Test("Boards and projects without cloud fields still decode")
    func tolerantDecoding() throws {
        let board = try JSONDecoder().decode(TaskBoard.self, from: Data(#"{"tasks":[]}"#.utf8))
        #expect(board.cloudSync == nil)

        let project = try JSONDecoder().decode(
            Project.self,
            from: Data(#"{"id":"\#(UUID().uuidString)","name":"P","path":"/tmp/p"}"#.utf8)
        )
        #expect(project.cloudId == nil)
        #expect(!project.isCloud)
    }

    @Test("Cloud sync state round trips with the board")
    func syncStateRoundTrip() throws {
        let taskId = UUID()
        var board = TaskBoard()
        board.cloudSync = CloudBoardSyncState(
            tasks: [taskId: CloudItemLink(remoteId: "r", base: CloudTaskFields(title: "T", version: "v2"))],
            lastSyncedAt: Date(timeIntervalSince1970: 1_000)
        )
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.cloudSync == board.cloudSync)
        #expect(decoded.cloudSync?.localTaskId(forRemote: "r") == taskId)
    }
}
