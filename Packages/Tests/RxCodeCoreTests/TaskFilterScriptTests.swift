import Foundation
import Testing
@testable import RxCodeCore

@Suite("Task filter script")
struct TaskFilterScriptTests {
    private func makeBoard() -> (TaskBoard, story: ProjectStory, open: ProjectTask, done: ProjectTask) {
        let projectId = UUID()
        let story = ProjectStory(projectId: projectId, title: "Filters", tags: ["ui"])
        let open = ProjectTask(
            projectId: projectId,
            storyId: story.id,
            title: "Write the harness",
            status: .pending,
            tags: ["backend"],
            priority: .high
        )
        let done = ProjectTask(projectId: projectId, title: "Ship it", status: .done)
        return (TaskBoard(stories: [story], tasks: [open, done]), story, open, done)
    }

    @Test("Input flattens tasks and stories with column names and rollups")
    func inputFlattensBoard() {
        let (board, story, open, done) = makeBoard()
        let input = TaskFilterScript.input(for: board)

        let openRecord = try! #require(input.tasks.first { $0.id == open.id.uuidString })
        #expect(openRecord.status == board.column(for: .pending).name)
        #expect(openRecord.isDone == false)
        #expect(openRecord.priority == "high")
        #expect(openRecord.storyTitle == "Filters")
        #expect(openRecord.tags == ["backend"])

        let doneRecord = try! #require(input.tasks.first { $0.id == done.id.uuidString })
        #expect(doneRecord.isDone)

        let storyRecord = try! #require(input.stories.first)
        #expect(storyRecord.id == story.id.uuidString)
        #expect(storyRecord.taskCount == 1)
        #expect(storyRecord.doneTaskCount == 0)
    }

    @Test("Selection parses ids and drops malformed ones")
    func selectionParsesIds() throws {
        let id = UUID()
        let data = Data(#"{"tasks":["\#(id.uuidString)","nope"],"stories":[]}"#.utf8)
        let selection = TaskFilterScript.Selection(try TaskFilterScript.decodeOutput(data))
        #expect(selection.taskIds == [id])
        #expect(selection.storyIds.isEmpty)
    }

    @Test("Swift is extracted from fenced replies")
    func extractsFencedSwift() {
        let raw = "Here you go:\n```swift\nfunc includeTask(_ task: FilterTask) -> Bool { true }\n```\nDone."
        #expect(TaskFilterScript.extractSwift(from: raw) == "func includeTask(_ task: FilterTask) -> Bool { true }")
        #expect(TaskFilterScript.extractSwift(from: "  \n ") == nil)
    }

    @Test("Saved views round trip their filter script and decode without one")
    func savedViewScriptRoundTrip() throws {
        let view = TaskSavedView(name: "Hot", filterScript: TaskFilterScript.starterScript)
        let decoded = try JSONDecoder().decode(TaskSavedView.self, from: JSONEncoder().encode(view))
        #expect(decoded.filterScript == TaskFilterScript.starterScript)
        #expect(decoded.hasFilterScript)

        let legacy = try JSONDecoder().decode(TaskSavedView.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(legacy.filterScript == nil)
        #expect(!legacy.hasFilterScript)
    }

    @Test("The harness compiles and filters the starter script end to end")
    func harnessRunsStarterScript() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return }
        let (board, story, open, _) = makeBoard()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskFilterScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("filter.swift")
        let binary = dir.appendingPathComponent("filter")
        try TaskFilterScript.harness(userScript: TaskFilterScript.starterScript)
            .write(to: source, atomically: true, encoding: .utf8)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-Onone", "-parse-as-library", source.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)

        let runner = Process()
        runner.executableURL = binary
        let input = Pipe()
        let output = Pipe()
        runner.standardInput = input
        runner.standardOutput = output
        try runner.run()
        try input.fileHandleForWriting.write(contentsOf: TaskFilterScript.encode(TaskFilterScript.input(for: board)))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        runner.waitUntilExit()

        let selection = TaskFilterScript.Selection(try TaskFilterScript.decodeOutput(data))
        // Starter keeps unfinished urgent/high tasks and unfinished stories.
        #expect(selection.taskIds == [open.id])
        #expect(selection.storyIds == [story.id])
    }
}
