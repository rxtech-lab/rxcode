import Foundation
import Testing
@testable import RxCodeCore

@Suite("Git history parsing")
struct GitHistoryParsingTests {
    @Test("Log records keep multi-line bodies, parents, and decorations")
    func parsesLog() {
        let raw = "aaa\u{1F}bbb ccc\u{1F}Ada\u{1F}ada@example.com\u{1F}1700000000\u{1F}HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1\u{1F}Merge feature\u{1F}Line one\nLine two\n\u{1E}\n"
            + "bbb\u{1F}\u{1F}Ada\u{1F}ada@example.com\u{1F}1690000000\u{1F}\u{1F}Initial\u{1F}\u{1E}"
        let commits = GitHistoryParser.parseLog(raw)
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["bbb", "ccc"])
        #expect(commits[0].isMerge)
        #expect(commits[0].body == "Line one\nLine two")
        #expect(commits[0].fullMessage == "Merge feature\n\nLine one\nLine two")
        #expect(commits[0].refs.first == GitRef(kind: .localBranch, name: "main", isCurrent: true))
        #expect(commits[0].refs.contains(GitRef(kind: .remoteBranch, name: "origin/main")))
        #expect(commits[0].refs.contains(GitRef(kind: .tag, name: "v1")))
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].refs.isEmpty)
    }

    @Test("Detached HEAD and remote HEAD decorations")
    func parsesDetachedDecorations() {
        let refs = GitHistoryParser.parseDecorations("HEAD, refs/remotes/origin/HEAD, refs/remotes/origin/dev")
        #expect(refs == [GitRef(kind: .head, name: "HEAD"), GitRef(kind: .remoteBranch, name: "origin/dev")])
    }

    @Test("Name-status output with renames")
    func parsesNameStatus() {
        let files = GitHistoryParser.parseNameStatus("M\0a.swift\0R087\0old.swift\0new.swift\0A\0dir/b.txt\0")
        #expect(files == [
            GitCommitFile(status: "M", path: "a.swift"),
            GitCommitFile(status: "R", path: "new.swift", originalPath: "old.swift"),
            GitCommitFile(status: "A", path: "dir/b.txt"),
        ])
    }

    @Test("Upstream tracking counts")
    func parsesTrack() {
        #expect(GitHistoryParser.parseTrack("[ahead 2, behind 1]") == (2, 1))
        #expect(GitHistoryParser.parseTrack("[behind 4]") == (0, 4))
        #expect(GitHistoryParser.parseTrack("[gone]") == (0, 0))
        #expect(GitHistoryParser.parseTrack("") == (0, 0))
    }
}

@Suite("Git graph layout")
struct GitGraphLayoutTests {
    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, authorName: "", authorEmail: "", authorDate: .now, subject: id)
    }

    @Test("Linear history stays in one lane")
    func linear() {
        let rows = GitGraphLayout.layout([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(rows.map(\.column) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(!rows[2].segments.contains { $0.to == .bottom })
    }

    @Test("A merge opens a second lane that rejoins at the fork point")
    func mergeAndFork() {
        // m merges f into b; both descend from a.
        let rows = GitGraphLayout.layout([
            commit("m", ["b", "f"]),
            commit("f", ["a"]),
            commit("b", ["a"]),
            commit("a", []),
        ])
        #expect(rows.map(\.column) == [0, 1, 0, 0])
        #expect(rows[0].segments.contains(.init(fromColumn: 0, from: .center, toColumn: 1, to: .bottom, colorIndex: rows[1].colorIndex)))
        // b's row passes lane 1 through, then a collects both lanes.
        #expect(rows[2].segments.contains { $0.fromColumn == 1 && $0.toColumn == 1 && $0.from == .top && $0.to == .bottom })
        let incoming = rows[3].segments.filter { $0.to == .center }
        #expect(Set(incoming.map(\.fromColumn)) == [0, 1])
        #expect(rows[3].width == 2)
    }

    @Test("Separate branch tips get separate lanes")
    func twoTips() {
        let rows = GitGraphLayout.layout([commit("x", ["a"]), commit("y", ["a"]), commit("a", [])])
        #expect(rows[0].column == 0)
        #expect(rows[1].column == 1)
        // y's lane merges into the lane already waiting for a.
        #expect(rows[1].segments.contains(.init(fromColumn: 1, from: .center, toColumn: 0, to: .bottom, colorIndex: rows[1].colorIndex)))
        #expect(rows[2].column == 0)
    }
}

@Suite("Interactive rebase plan")
struct GitRebasePlanTests {
    @Test("Todo turns rewords into pick plus amend exec")
    func todo() {
        let steps = [
            GitRebaseStep(commit: "a1", subject: "First", action: .reword, message: "New"),
            GitRebaseStep(commit: "b2", subject: "Second", action: .squash),
            GitRebaseStep(commit: "c3", subject: "Third", action: .drop),
        ]
        let todo = GitRebasePlan.todo(for: steps) { _ in "/tmp/it's here.txt" }
        #expect(todo == """
        pick a1 First
        exec git commit --amend --allow-empty --only --cleanup=strip -F '/tmp/it'\\''s here.txt'
        squash b2 Second
        drop c3 Third

        """)
    }

    @Test("Validation")
    func validation() {
        #expect(GitRebasePlan.validate([GitRebaseStep(commit: "a", subject: "", action: .drop)]) == .empty)
        #expect(GitRebasePlan.validate([
            GitRebaseStep(commit: "a", subject: "", action: .drop),
            GitRebaseStep(commit: "b", subject: "", action: .fixup),
        ]) == .squashWithoutTarget)
        #expect(GitRebasePlan.validate([GitRebaseStep(commit: "a", subject: "", action: .reword, message: " ")]) == .emptyRewordMessage)
        #expect(GitRebasePlan.validate([GitRebaseStep(commit: "a", subject: ""), GitRebaseStep(commit: "b", subject: "", action: .squash)]) == nil)
    }
}

#if os(macOS)
@Suite("Git workflow commands", .timeLimit(.minutes(1)))
struct GitWorkflowIntegrationTests {
    private func git(_ args: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
    }

    private func makeRepo(commits: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: root)
        try git(["config", "user.name", "Test"], at: root)
        try git(["config", "user.email", "test@example.com"], at: root)
        try git(["config", "commit.gpgsign", "false"], at: root)
        for (index, message) in commits.enumerated() {
            try Data("\(index)\n".utf8).write(to: root.appendingPathComponent("file\(index).txt"))
            try git(["add", "."], at: root)
            try git(["commit", "-q", "-m", message], at: root)
        }
        return root
    }

    private func subjects(at root: URL) async -> [String] {
        await GitRepositoryLoader.history(at: root.path, ref: "HEAD", limit: 50).map(\.subject)
    }

    private func addRemote(_ name: String, to repo: URL) throws -> URL {
        let remote = repo.appending(path: ".git/test-remotes/\(name)")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], at: repo)
        try git(["remote", "add", name, remote.path], at: repo)
        return remote
    }

    @Test("A push uses the selected remote and preserves the branch's existing upstream")
    func pushToSelectedRemote() async throws {
        let repo = try makeRepo(commits: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let origin = try addRemote("origin", to: repo)
        let backup = try addRemote("team/backup", to: repo)
        try git(["push", "-q", "origin", "HEAD^:refs/heads/release"], at: repo)
        try git(["branch", "--set-upstream-to=origin/release", "main"], at: repo)
        try git(["tag", "main"], at: repo)
        try git(["tag", "releases/v1", "HEAD^"], at: repo)

        let branch = try #require(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch)
        #expect(branch.name == "main")
        #expect(branch.upstreamRemote == "origin")
        #expect(await GitWorkflow.push(branch: branch, remote: "team/backup", force: false, pushAllTags: true, at: repo.path) == nil)

        let backupSnapshot = await GitRepositoryLoader.snapshot(at: backup.path)
        #expect(backupSnapshot.localBranches.map(\.name) == ["main"])
        #expect(backupSnapshot.localBranches.first?.tip == branch.tip)
        #expect(Set(backupSnapshot.tags.map(\.name)) == ["main", "releases/v1"])
        #expect(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch?.upstream == "origin/release")

        #expect(await GitWorkflow.push(branch: branch, remote: "origin", force: false, at: repo.path) == nil)
        let originSnapshot = await GitRepositoryLoader.snapshot(at: origin.path)
        #expect(originSnapshot.localBranches.map(\.name) == ["release"])
        #expect(originSnapshot.localBranches.first?.tip == branch.tip)
        #expect(originSnapshot.tags.isEmpty)
    }

    @Test("Force push with tags protects the lease and existing tags")
    func forcePushWithTags() async throws {
        let repo = try makeRepo(commits: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let origin = try addRemote("origin", to: repo)
        try git(["tag", "stable"], at: repo)
        let unpublished = try #require(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch)
        #expect(await GitWorkflow.push(branch: unpublished, remote: "origin", force: false, pushAllTags: true, at: repo.path) == nil)
        #expect(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch?.upstream == "origin/main")

        try git(["reset", "--hard", "HEAD^"], at: repo)
        try git(["tag", "older"], at: repo)
        let branch = try #require(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch)
        #expect(await GitWorkflow.push(branch: branch, remote: "origin", force: true, pushAllTags: true, at: repo.path) == nil)
        let pushed = await GitRepositoryLoader.snapshot(at: origin.path)
        #expect(pushed.currentLocalBranch?.tip == branch.tip)
        #expect(Set(pushed.tags.map(\.name)) == ["older", "stable"])

        try git(["update-ref", "refs/heads/main", unpublished.tip], at: origin)
        #expect(await GitWorkflow.push(branch: branch, remote: "origin", force: true, at: repo.path) != nil)
        #expect(await GitRepositoryLoader.snapshot(at: origin.path).currentLocalBranch?.tip == unpublished.tip)

        try git(["fetch", "-q", "origin"], at: repo)
        try git(["tag", "-f", "stable"], at: repo)
        #expect(await GitWorkflow.push(branch: branch, remote: "origin", force: true, pushAllTags: true, at: repo.path) != nil)
        let afterConflict = await GitRepositoryLoader.snapshot(at: origin.path)
        #expect(afterConflict.tags.first { $0.name == "stable" }?.tip == unpublished.tip)
    }

    @Test("Reword an older commit without an editor")
    func rewordOlderCommit() async throws {
        let repo = try makeRepo(commits: ["one", "two", "three"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let history = await GitRepositoryLoader.history(at: repo.path, ref: "HEAD", limit: 10)
        let target = try #require(history.first { $0.subject == "two" })
        #expect(await GitWorkflow.reword(target, message: "two, reworded\n\nWith body", at: repo.path) == nil)
        #expect(await subjects(at: repo) == ["three", "two, reworded", "one"])
        #expect(await GitRepositoryLoader.pendingOperation(at: repo.path) == nil)
    }

    @Test("Reword HEAD ignores staged changes")
    func rewordHead() async throws {
        let repo = try makeRepo(commits: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("staged\n".utf8).write(to: repo.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"], at: repo)
        let head = try #require(await GitRepositoryLoader.history(at: repo.path, ref: "HEAD", limit: 1).first)
        #expect(await GitWorkflow.reword(head, message: "two!", at: repo.path) == nil)
        #expect(await subjects(at: repo) == ["two!", "one"])
        let files = await GitRepositoryLoader.files(in: try #require(await GitRepositoryLoader.history(at: repo.path, ref: "HEAD", limit: 1).first), at: repo.path)
        #expect(files.map(\.path) == ["file1.txt"])
    }

    @Test("Interactive rebase reorders, squashes, and drops")
    func interactiveRebase() async throws {
        let repo = try makeRepo(commits: ["one", "two", "three", "four"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let history = await GitRepositoryLoader.history(at: repo.path, ref: "HEAD", limit: 10)
        let from = try #require(history.first { $0.subject == "two" })
        var steps = try #require(await GitWorkflow.rebaseSteps(from: from, at: repo.path))
        #expect(steps.map(\.subject) == ["two", "three", "four"])
        steps.swapAt(0, 2) // four, three, two
        steps[1].action = .fixup
        steps[2].action = .drop
        #expect(await GitWorkflow.interactiveRebase(steps, base: from.parents.first, at: repo.path) == nil)
        #expect(await subjects(at: repo) == ["four", "one"])
        let snapshot = await GitRepositoryLoader.snapshot(at: repo.path)
        #expect(snapshot.currentBranch == "main")
        #expect(snapshot.pendingOperation == nil)
    }
}
#endif
