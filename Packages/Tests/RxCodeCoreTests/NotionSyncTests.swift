import Foundation
import Testing
@testable import RxCodeCore

@Suite("Notion sync")
struct NotionSyncTests {

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func database() throws -> NotionDatabase {
        let value = try json("""
        {
          "object": "database",
          "id": "db-1",
          "title": [{"plain_text": "Roadmap"}],
          "properties": {
            "Name": {"name": "Name", "type": "title", "title": {}},
            "Status": {"name": "Status", "type": "status", "status": {"options": [{"name": "Backlog"}, {"name": "In progress"}, {"name": "Done"}]}},
            "Priority": {"name": "Priority", "type": "select", "select": {"options": [{"name": "High"}]}},
            "Tags": {"name": "Tags", "type": "multi_select", "multi_select": {"options": []}},
            "Version": {"name": "Version", "type": "rich_text", "rich_text": {}},
            "Story": {"name": "Story", "type": "select", "select": {"options": []}},
            "Estimate": {"name": "Estimate", "type": "number", "number": {}}
          }
        }
        """)
        return try #require(NotionDatabase(json: value))
    }

    @Test("Database schema maps conventional property names")
    func fieldMap() throws {
        let db = try database()
        #expect(db.title == "Roadmap")
        let map = try #require(NotionFieldMap(database: db))
        #expect(map.title.name == "Name")
        #expect(map.status?.type == "status")
        #expect(map.priority?.name == "Priority")
        #expect(map.tags?.name == "Tags")
        #expect(map.version?.type == "rich_text")
        #expect(map.story?.name == "Story")
        #expect(map.milestone == nil)
        #expect(map.description == nil)
    }

    @Test("Push writes mapped fields and only known status options")
    func pushProperties() throws {
        let map = try #require(NotionFieldMap(database: database()))
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Launch")
        var task = ProjectTask(
            projectId: projectId,
            storyId: story.id,
            title: "Ship it",
            status: .done,
            version: "v1.2",
            tags: ["ui", "a,b"],
            priority: .high
        )
        let board = TaskBoard(stories: [story], tasks: [task])

        let props = NotionTaskMapper.properties(for: task, board: board, map: map)
        #expect(NotionText.plainText(props["Name"]?["title"]) == "Ship it")
        #expect(props["Status"]?["status"]?["name"]?.stringValue == "Done")
        #expect(props["Priority"]?["select"]?["name"]?.stringValue == "High")
        #expect(props["Tags"]?["multi_select"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["ui", "a b"])
        #expect(NotionText.plainText(props["Version"]?["rich_text"]) == "v1.2")
        #expect(props["Story"]?["select"]?["name"]?.stringValue == "Launch")

        // "Pending Review" isn't a status option, so the status is left alone.
        task.status = .pendingReview
        let unmatched = NotionTaskMapper.properties(for: task, board: board, map: map)
        #expect(unmatched["Status"] == nil)
        #expect(NotionTaskMapper.fingerprint(props) != NotionTaskMapper.fingerprint(unmatched))
        #expect(NotionTaskMapper.fingerprint(props) == NotionTaskMapper.fingerprint(props))
    }

    @Test("Long text is split into Notion-sized chunks")
    func richTextChunks() {
        let text = String(repeating: "a", count: 4500)
        let chunks = NotionText.richText(text).arrayValue ?? []
        #expect(chunks.count == 3)
        #expect(NotionText.plainText(.array(chunks)) == text)
    }

    @Test("Import maps pages onto columns, stories and priority, and skips linked pages")
    func importPages() throws {
        let map = try #require(NotionFieldMap(database: database()))
        let pages = try json("""
        [
          {"id": "page-1", "properties": {
            "Name": {"type": "title", "title": [{"plain_text": "Fix login"}]},
            "Status": {"type": "status", "status": {"name": "done"}},
            "Priority": {"type": "select", "select": {"name": "high"}},
            "Tags": {"type": "multi_select", "multi_select": [{"name": "auth"}]},
            "Story": {"type": "select", "select": {"name": "Accounts"}}
          }},
          {"id": "page-2", "properties": {
            "Name": {"type": "title", "title": [{"plain_text": "Write docs"}]},
            "Status": {"type": "status", "status": {"name": "In progress"}}
          }},
          {"id": "page-3", "in_trash": true, "properties": {}}
        ]
        """).arrayValue ?? []
        let items = pages.compactMap { NotionTaskMapper.importedItem(from: $0, map: map) }
        #expect(items.count == 2)

        let projectId = UUID()
        var board = TaskBoard()
        let link = NotionBoardLink(databaseId: "db-1", databaseTitle: "Roadmap")
        let result = board.applyNotionImport(items, projectId: projectId, link: link)
        #expect(result == NotionImportResult(added: 2, skipped: 0, storiesCreated: 1))

        let login = try #require(board.tasks.first { $0.title == "Fix login" })
        #expect(login.status == .done)
        #expect(login.priority == .high)
        #expect(login.tags == ["auth"])
        #expect(board.story(id: login.storyId)?.title == "Accounts")

        // "In progress" matches the chat column, which would start an agent,
        // so the task lands in the first non-chat column instead.
        let docs = try #require(board.tasks.first { $0.title == "Write docs" })
        #expect(docs.status == .backlog)

        #expect(board.notion?.taskId(forPage: "page-1") == login.id)

        let again = board.applyNotionImport(items, projectId: projectId, link: try #require(board.notion))
        #expect(again == NotionImportResult(added: 0, skipped: 2, storiesCreated: 0))
        #expect(board.tasks.count == 2)
    }

    @Test("A board written before Notion sync decodes without a link, and the link round trips")
    func boardCoding() throws {
        let legacy = try JSONDecoder().decode(TaskBoard.self, from: Data(#"{"tasks": []}"#.utf8))
        #expect(legacy.notion == nil)

        let taskId = UUID()
        var board = TaskBoard()
        board.notion = NotionBoardLink(
            databaseId: "db-1",
            databaseTitle: "Roadmap",
            autoSync: true,
            pages: [taskId.uuidString: NotionPageLink(pageId: "abc-def", fingerprint: "x")]
        )
        let decoded = try JSONDecoder().decode(TaskBoard.self, from: JSONEncoder().encode(board))
        #expect(decoded.notion == board.notion)
        #expect(decoded.notion?.taskId(forPage: "ABCDEF") == taskId)
    }

    /// The Notion "Projects" template: a data source whose Status options are
    /// Not started / In progress / Done in the To-do / In progress / Complete
    /// groups, and no Tags, Version, … properties.
    private func projectsDataSource() throws -> NotionDatabase {
        let value = try json("""
        {
          "object": "data_source",
          "id": "ds-1",
          "parent": {"type": "database_id", "database_id": "db-1"},
          "title": [{"plain_text": "Projects"}],
          "properties": {
            "Project name": {"name": "Project name", "type": "title", "title": {}},
            "Priority": {"name": "Priority", "type": "select", "select": {"options": [{"id": "p1", "name": "High"}]}},
            "Status": {"name": "Status", "type": "status", "status": {
              "options": [{"id": "s1", "name": "Not started"}, {"id": "s2", "name": "In progress"}, {"id": "s3", "name": "Done"}],
              "groups": [
                {"name": "To-do", "option_ids": ["s1"]},
                {"name": "In progress", "option_ids": ["s2"]},
                {"name": "Complete", "option_ids": ["s3"]}
              ]
            }},
            "Type": {"name": "Type", "type": "people", "people": {}}
          }
        }
        """)
        return try #require(NotionDatabase(json: value))
    }

    @Test("Columns map onto a status property's groups when names don't match")
    func statusGroups() throws {
        let db = try projectsDataSource()
        #expect(db.id == "ds-1")
        #expect(db.databaseId == "db-1")
        let map = try #require(NotionFieldMap(database: db))
        #expect(map.status?.group(of: "done") == .complete)

        let projectId = UUID()
        let board = TaskBoard()
        func pushedStatus(_ status: TaskStatus) -> String? {
            let task = ProjectTask(projectId: projectId, title: "T", status: status)
            return NotionTaskMapper.properties(for: task, board: board, map: map)["Status"]?["status"]?["name"]?.stringValue
        }
        #expect(pushedStatus(.done) == "Done")
        #expect(pushedStatus(.inProgress) == "In progress")
        #expect(pushedStatus(.pendingReview) == "In progress")
        #expect(pushedStatus(.pending) == "Not started")
        #expect(pushedStatus(.backlog) == "Not started")
    }

    @Test("Missing task fields are added, avoiding names taken by other types")
    func missingProperties() throws {
        let db = try projectsDataSource()
        let missing = NotionFieldMap.missingProperties(in: db, board: TaskBoard())
        #expect(Set(missing.keys) == ["Tags", "Version", "Milestone", "RxCode Type", "Story", "Description"])
        #expect(missing["Description"]?["rich_text"] != nil)
        let typeOptions = missing["RxCode Type"]?["select"]?["options"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(typeOptions == TaskItemType.defaults.map(\.name))

        // Once added, every field maps and nothing is missing.
        var withAdded = db
        for (name, schema) in missing {
            let type = schema.objectValue?.keys.first ?? ""
            withAdded.properties.append(NotionProperty(name: name, type: type))
        }
        let map = try #require(NotionFieldMap(database: withAdded))
        #expect(map.type?.name == "RxCode Type")
        #expect(map.description?.name == "Description")
        #expect(NotionFieldMap.missingProperties(in: withAdded, board: TaskBoard()).isEmpty)
    }

    @Test("Imported pages in the Complete group land in the done column")
    func importCompleteGroup() throws {
        let map = try #require(NotionFieldMap(database: projectsDataSource()))
        let page = try json("""
        {"id": "page-9", "properties": {
          "Project name": {"type": "title", "title": [{"plain_text": "Shipped"}]},
          "Status": {"type": "status", "status": {"name": "Done"}}
        }}
        """)
        var item = try #require(NotionTaskMapper.importedItem(from: page, map: map))
        #expect(item.statusGroup == .complete)

        var board = TaskBoard(columns: TaskColumn.defaults.map { column in
            var renamed = column
            if column.id == .done { renamed.name = "Shipped" }
            return renamed
        })
        item.statusName = "Finished"
        _ = board.applyNotionImport([item], projectId: UUID(), link: NotionBoardLink(databaseId: "ds-1", databaseTitle: "Projects"))
        #expect(board.tasks.first?.status == .done)
    }
}
