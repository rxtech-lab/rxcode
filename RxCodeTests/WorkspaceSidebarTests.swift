import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import ViewInspector
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
            "atlas": SessionActivity(isStreaming: true, hasUncheckedCompletion: true),
            "beacon": SessionActivity(isStreaming: true),
            "old": SessionActivity(hasUncheckedCompletion: true),
        ]
        app.todoProgressBySession["beacon"] = .init(done: 1, total: 3, inProgress: true)
        window.pendingPermissions = [.init(id: "permission", toolName: "Edit", toolInput: [:], runToken: "run", sessionId: "pending-beacon")]
        let runs = app.sidebarRuns(in: window)
        XCTAssertEqual(runs.map(\.id), ["beacon", "atlas", "old"])
        XCTAssertEqual(runs.map(\.status), [.needsApproval, .running, .completedUnread])
        XCTAssertEqual(runs.first?.title, "Fix indexing")
        XCTAssertEqual(runs.first?.progress?.done, 1)
        window.pendingPermissions = []
        app.sessionActivity["beacon"] = .init(hasUncheckedCompletion: true)
        app.sessionActivity["check"] = .init(isStreaming: true)
        let updated = app.sidebarRuns(in: window)
        XCTAssertEqual(updated.map(\.id), ["atlas", "old", "beacon", "check"])
        XCTAssertEqual(updated.map(\.status), [.running, .completedUnread, .completedUnread, .verifying])
        XCTAssertEqual(updated.first { $0.id == "check" }?.title, "Fix indexing")
        app.sessionActivity.removeAll()
        XCTAssertTrue(app.sidebarRuns(in: window).isEmpty)
    }

    func testFinishedThreadsStayInActiveNowUntilViewed() {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let a = Project(name: "Atlas", path: "/atlas")
        let b = Project(name: "Beacon", path: "/beacon")
        let visible = ChatSession(id: "visible", projectId: a.id)
        let covered = ChatSession(id: "covered", projectId: a.id)
        let background = ChatSession(id: "background", projectId: b.id)
        app.projects = [a, b]
        window.selectedProject = a
        app.allSessionSummaries = [visible.summary, covered.summary, background.summary]
        for thread in [visible, covered, background] {
            app.updateState(thread.id) { state in
                state.isStreaming = true
                state.messages = [ChatMessage(role: .assistant, content: "Finished")]
            }
        }
        let bridge = ChatBridge()
        func chat(focus: ControlActiveState) -> some View {
            Text("Chat")
                .modifier(ChatDetailModifiers())
                .environment(app).environment(window).environment(bridge)
                .environment(\.controlActiveState, focus)
        }
        app.sessionIdRedirect["pending-visible"] = visible.id
        window.currentSessionId = "pending-visible"
        let host = NSHostingView(rootView: chat(focus: .key))
        let hostWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 220),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.contentView = host
        hostWindow.orderBack(nil)
        defer { hostWindow.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        app.finalizeStreamSession(for: visible.id, trackUnreadCompletion: true)
        host.rootView = chat(focus: .inactive)
        window.currentSessionId = covered.id
        host.layoutSubtreeIfNeeded()
        app.finalizeStreamSession(for: covered.id, trackUnreadCompletion: true)
        app.finalizeStreamSession(for: background.id, trackUnreadCompletion: true)
        let completed = app.sidebarRuns(in: window)
        XCTAssertEqual(completed.map(\.id), [covered.id, background.id])
        XCTAssertEqual(completed.map(\.status), [.completedUnread, .completedUnread])

        app.selectProject(b, in: window)
        XCTAssertEqual(app.sidebarRuns(in: window).map(\.id), [covered.id, background.id])
        app.selectSession(id: background.id, in: window)
        XCTAssertEqual(app.sidebarRuns(in: window).map(\.id), [covered.id])
        window.currentSessionId = covered.id
        host.rootView = chat(focus: .key)
        host.layoutSubtreeIfNeeded()
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

    func testGitWindowPollsRemoteBranchesAndShowsTheDeleteOption() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: String...) async throws {
            if let error = await GitHelper.runWithError(arguments, at: repo.path) {
                XCTFail(error)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try await git("init", "-b", "publisher")
        for message in ["First", "Second"] {
            try await git("-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                          "commit", "--allow-empty", "-m", message)
        }
        try await git("init", "--bare", "-b", "main", ".git/server")
        try await git("remote", "add", "origin", repo.appending(path: ".git/server").path)
        try await git("push", "origin", "HEAD:refs/heads/publisher", "HEAD^:refs/heads/main")
        try await git("branch", "--track", "review", "origin/main")
        let store = GitWorkflowStore(root: repo.path)
        await store.reload()
        let review = try XCTUnwrap(store.snapshot.localBranches.first { $0.name == "review" })
        let sheet = GitDeleteBranchSheet(store: store, branch: review)
        let toggle = try sheet.inspect().find(ViewType.Toggle.self)
        XCTAssertFalse(try toggle.isOn())
        XCTAssertEqual(try toggle.labelView().find(ViewType.Text.self).string(), "Also delete “origin/main” from the remote")

        try await git("-C", ".git/server", "update-ref", "refs/heads/main", "refs/heads/publisher")
        let polling = Task { await store.fetchRemotesPeriodically(every: .milliseconds(40)) }
        defer { polling.cancel() }
        func waitForCount(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while store.snapshot.localBranches.first(where: { $0.name == "review" })?.behind != count {
                guard ContinuousClock.now < deadline else { return XCTFail("Expected \(count) incoming commits") }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await waitForCount(1)
        let host = NSHostingView(rootView: GitWorkflowSidebar(store: store).environment(RepositoryStatus()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 310, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func tableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { tableView(in: $0) }.first
        }
        let table = try XCTUnwrap(tableView(in: host))
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await Task.yield()
            if store.selection == .branch("review") { break }
        }
        XCTAssertEqual(store.selection, .branch("review"))
        XCTAssertEqual(store.snapshot.currentBranch, "publisher")
        let rowBounds = table.rect(ofRow: table.selectedRow)
        let point = table.convert(CGPoint(x: rowBounds.midX, y: rowBounds.midY), to: nil)
        // Let AppKit dispatch the full double-click to the SwiftUI list.
        for click in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: click, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.postEvent(event, atStart: false)
            }
        }
        let checkoutDeadline = ContinuousClock.now + .seconds(5)
        while store.snapshot.currentBranch != "review", ContinuousClock.now < checkoutDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.snapshot.currentBranch, "review")
        try await git("-C", ".git/server", "update-ref", "refs/heads/main", "refs/heads/publisher^")
        try await waitForCount(0)
        polling.cancel()
        await polling.value
        XCTAssertNil(store.operation)
        XCTAssertNil(store.error)
    }

    func testGitSidebarSectionContextMenusCreateBranchAndTag() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: String...) async throws {
            if let error = await GitHelper.runWithError(arguments, at: repo.path) {
                XCTFail(error)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try await git("init", "-b", "main")
        try await git("-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                      "commit", "--allow-empty", "-m", "Initial commit")

        let store = GitWorkflowStore(root: repo.path)
        await store.reload()
        XCTAssertTrue(store.snapshot.tags.isEmpty)
        let head = try XCTUnwrap(store.snapshot.headCommit)

        let host = NSHostingView(rootView: GitWorkflowSidebar(store: store).environment(RepositoryStatus()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 310, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        func tableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { tableView(in: $0) }.first
        }
        func resolvedMenu(at row: Int, in table: NSTableView) throws -> NSMenu? {
            let rowBounds = table.rect(ofRow: row)
            guard rowBounds.height > 0 else { return nil }
            let pointInWindow = table.convert(CGPoint(x: rowBounds.midX, y: rowBounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: pointInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            let pointInHost = host.convert(pointInWindow, from: nil)
            var candidate = host.hitTest(pointInHost)
            while let view = candidate {
                if let menu = view.menu(for: event) {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    if !menu.items.isEmpty {
                        return menu
                    }
                }
                candidate = view.superview
            }
            return nil
        }

        let table = try XCTUnwrap(tableView(in: host))
        let menus = try (0..<table.numberOfRows).compactMap { try resolvedMenu(at: $0, in: table) }

        let branchesMenu = try XCTUnwrap(menus.first { $0.items.contains { $0.title == "New Branch…" } })
        let newBranchIndex = try XCTUnwrap(branchesMenu.items.firstIndex { $0.title == "New Branch…" })
        XCTAssertTrue(branchesMenu.items[newBranchIndex].isEnabled)
        branchesMenu.performActionForItem(at: newBranchIndex)
        if case .createBranch(let startPoint, let label) = store.sheet {
            XCTAssertEqual(startPoint, "HEAD")
            XCTAssertEqual(label, "main")
        } else {
            XCTFail("Expected createBranch sheet, got \(String(describing: store.sheet))")
        }

        store.sheet = nil

        let tagsMenu = try XCTUnwrap(menus.first { $0.items.contains { $0.title == "New Tag…" } })
        let newTagIndex = try XCTUnwrap(tagsMenu.items.firstIndex { $0.title == "New Tag…" })
        XCTAssertTrue(tagsMenu.items[newTagIndex].isEnabled)
        tagsMenu.performActionForItem(at: newTagIndex)
        if case .createTag(let target, let label) = store.sheet {
            XCTAssertEqual(target, head)
            XCTAssertTrue(label.contains("Initial commit"))
        } else {
            XCTFail("Expected createTag sheet, got \(String(describing: store.sheet))")
        }
    }
}
