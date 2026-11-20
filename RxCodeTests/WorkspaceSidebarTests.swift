import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class WorkspaceSidebarTests: XCTestCase {
    func testProjectAndThreadRowsFollowTheVisibleDestination() {
        let window = WindowState()
        let project = Project(name: "Atlas", path: "/atlas")
        window.selectedProject = project
        window.taskDetailProjectId = project.id
        window.currentSessionId = "thread"

        window.generalRoute = nil
        XCTAssertEqual(window.sidebarTreeSelection, .thread("thread"))
        window.generalRoute = .tasks
        XCTAssertEqual(window.sidebarTreeSelection, .project(project.id))
        window.taskDetailProjectId = nil
        XCTAssertNil(window.sidebarTreeSelection)
        for route in [GeneralRoute.scheduled, .briefing, .chat] {
            window.generalRoute = route
            XCTAssertNil(window.sidebarTreeSelection)
        }
        window.generalRoute = nil
        window.currentSessionId = nil
        XCTAssertEqual(window.sidebarTreeSelection, .project(project.id))
    }

    func testActivityAcrossProjectsCountsEachRunOnceAndPrioritizesApprovals() {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let a = Project(name: "Atlas", path: "/atlas")
        let b = Project(name: "Beacon", path: "/beacon")
        app.projects = [a, b]
        app.sessionIdRedirect["pending-beacon"] = "beacon"
        app.taskBoards[b.id] = TaskBoard(tasks: [
            ProjectTask(projectId: b.id, title: "Fix indexing", status: .inProgress, sessionKey: "pending-beacon"),
            ProjectTask(projectId: b.id, title: "Waiting in queue", status: .inProgress, isQueued: true),
        ])
        app.allSessionSummaries = [
            ChatSession(id: "atlas", projectId: a.id, title: "Audit settings").summary,
            ChatSession(id: "beacon", projectId: b.id, title: "Agent thread").summary,
            ChatSession(id: "check", projectId: b.id, parentThreadId: "beacon", threadLabel: TaskCompletionCheckLabel.inProgress).summary,
            ChatSession(id: "old", projectId: a.id).summary,
        ]
        app.sessionActivity = [
            "atlas": SessionActivity(isStreaming: true), "beacon": SessionActivity(isStreaming: true),
            "old": SessionActivity(hasUncheckedCompletion: true),
        ]
        app.todoProgressBySession["beacon"] = .init(done: 1, total: 3, inProgress: true)
        window.pendingPermissions = [.init(id: "permission", toolName: "Edit", toolInput: [:], runToken: "run", sessionId: "pending-beacon")]
        let runs = app.sidebarRuns(in: window)
        XCTAssertEqual(runs.map(\.id), ["beacon", "atlas"])
        XCTAssertEqual(runs.first?.title, "Fix indexing")
        XCTAssertEqual(runs.first?.status, .needsApproval)
        XCTAssertEqual(runs.first?.progress?.done, 1)
        window.pendingPermissions = []
        app.sessionActivity["beacon"] = .init(hasUncheckedCompletion: true)
        app.sessionActivity["check"] = .init(isStreaming: true)
        XCTAssertEqual(app.sidebarRuns(in: window).map(\.id), ["atlas", "check"])
        XCTAssertEqual(app.sidebarRuns(in: window).last?.status, .verifying)
        XCTAssertEqual(app.sidebarRuns(in: window).last?.title, "Fix indexing")
        app.sessionActivity.removeAll()
        XCTAssertTrue(app.sidebarRuns(in: window).isEmpty)
    }

    func testSourceControlTargetsTheChatCheckoutAndTheProjectBoardRoot() {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let project = Project(name: "Atlas", path: "/atlas")
        window.selectedProject = project
        window.generalRoute = nil
        window.pendingWorktreePath = "/pending"
        XCTAssertEqual(app.sourceControlPath(in: window), "/pending")
        window.currentSessionId = "thread"
        app.allSessionSummaries = [ChatSession(id: "thread", projectId: project.id, worktreePath: "/worktree").summary]
        XCTAssertEqual(app.sourceControlPath(in: window), "/worktree")
        window.generalRoute = .tasks
        XCTAssertEqual(app.sourceControlPath(in: window), "/atlas")
        window.selectedProject = app.globalChatProject
        XCTAssertNil(app.sourceControlPath(in: window))
    }

    func testWorkingTreeHandlesUnbornBranchMixedFilesRenamesAndDetachedWorktrees() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = await RepositoryState.load(at: repo.path)
        XCTAssertEqual(empty, .notRepository)

        func git(_ args: [String]) async throws {
            if let error = await GitHelper.runWithError(args, at: repo.path) { XCTFail(error); throw CocoaError(.fileWriteUnknown) }
        }
        try await git(["init", "-b", "main"])
        let file = repo.appendingPathComponent("a[1].txt")
        try "original\n".write(to: file, atomically: false, encoding: .utf8)
        let stageError = await GitHelper.stage(paths: [file.lastPathComponent], at: repo.path)
        XCTAssertNil(stageError)
        let unstageError = await GitHelper.unstage(paths: [file.lastPathComponent], at: repo.path)
        XCTAssertNil(unstageError)
        try await git(["add", "-A"])
        try "updated\n".write(to: file, atomically: false, encoding: .utf8)
        guard case .ready(let initial) = await RepositoryState.load(at: repo.path) else { return XCTFail("Missing unborn branch") }
        XCTAssertEqual(initial.head, "main")
        XCTAssertEqual(initial.changes.staged.map(\.displayPath), [file.lastPathComponent])
        XCTAssertEqual(initial.changes.unstaged.map(\.displayPath), [file.lastPathComponent])
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture"])
        try await git(["mv", "a[1].txt", "new name"])
        guard case .ready(let renamed) = await RepositoryState.load(at: repo.path) else { return XCTFail("Missing rename") }
        XCTAssertEqual(renamed.changes.staged.first?.pathspecs, ["new name", "a[1].txt"])
        let worktree = root.appendingPathComponent("linked")
        try await git(["worktree", "add", "--detach", worktree.path, "HEAD"])
        guard case .ready(let detached) = await RepositoryState.load(at: worktree.path) else { return XCTFail("Missing worktree") }
        XCTAssertTrue(detached.isDetached)
        XCTAssertTrue(detached.changes.staged.isEmpty)
        XCTAssertTrue(detached.changes.unstaged.isEmpty)
        let actual = try FileManager.default.attributesOfItem(atPath: detached.root)
        let expected = try FileManager.default.attributesOfItem(atPath: worktree.path)
        XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
    }
}
