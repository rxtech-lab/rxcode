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

    @Test("Numstat preserves unusual paths, renames and binary changes")
    func parsesNumstat() {
        let raw = "2\t3\ttab\tand\nnewline\0-\t-\timage.png\0" + "0\t0\t\0old\0folder/new\0"
        #expect(GitLineChanges.parseNumstat(raw) == [
            "tab\tand\nnewline": .text(added: 2, deleted: 3),
            "image.png": .binary,
            "folder/new": .text(added: 0, deleted: 0),
        ])
    }

    @Test("Folder selection includes descendants once and keeps sibling paths and replacement files distinct")
    func folderSelection() {
        let tree = GitPathTree(paths: ["Src/Old", "Src/Old/new.swift", "Src/a.swift", "SrcTests/a.swift", "top.txt"])
        #expect(tree.roots.map(\.id) == ["Src/", "SrcTests/", "top.txt"])
        #expect(tree.roots.first?.fileCount == 3)
        #expect(tree.folders == ["Src/", "Src/Old/", "SrcTests/"])
        #expect(tree.visibleRows(collapsing: ["Src/"]).map(\.id) == ["Src/", "SrcTests/", "SrcTests/a.swift", "top.txt"])
        #expect(tree.visibleRows(collapsing: []).first { $0.id == "Src/Old/new.swift" }?.depth == 2)
        #expect(tree.filePaths(in: ["Src/Old/"]) == ["Src/Old/new.swift"])
        #expect(tree.filePaths(in: ["Src/Old"]) == ["Src/Old"])
        #expect(Set(tree.filePaths(in: ["Src/", "Src/Old/", "Src/a.swift", "top.txt"])) == ["Src/Old", "Src/Old/new.swift", "Src/a.swift", "top.txt"])
        #expect(tree.filePaths(in: ["Src/", "Src/Old/"]).count == 3)
        #expect(tree.filePaths(in: []).isEmpty)
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

    @Test("Primary branches stay first and publishing respects the chosen branch, destination and tracking option")
    func publishUntrackedBranch() async throws {
        let repo = try makeRepo(commits: ["base"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let initial = await GitRepositoryLoader.snapshot(at: repo.path)
        let main = try #require(initial.currentLocalBranch)
        #expect(initial.pushDestinations(for: main).isEmpty)
        let remote = repo.appending(path: ".git/test-remotes/backup")
        try git(["init", "-q", "--bare", "-b", "main", remote.path], at: repo)
        #expect(await GitWorkflow.addRemote(name: "team/backup", url: remote.path, at: repo.path) == nil)
        #expect(await GitHelper.runWithError(["fetch", "--", "team/backup"], at: repo.path) == nil)
        for name in ["master", "aaa", "feature/main"] { try git(["branch", name], at: repo) }
        try git(["push", "-q", "team/backup", "main", "master", "aaa"], at: repo)
        let snapshot = await GitRepositoryLoader.snapshot(at: repo.path)
        #expect(snapshot.localBranches.map(\.name) == ["main", "master", "aaa", "feature/main"])
        #expect(snapshot.remoteBranches.map(\.name) == ["main", "master", "aaa"])
        #expect(Array(await GitHelper.listLocalBranches(at: repo.path).prefix(2)) == ["main", "master"])
        let feature = try #require(snapshot.localBranches.first { $0.name == "feature/main" })
        let options = snapshot.pushDestinations(for: feature)
        #expect(options.map(\.displayName) == ["team/backup/main", "team/backup/master", "team/backup/aaa", "team/backup/feature/main"])
        #expect(options.map(\.isNew) == [false, false, false, true])
        let target = try #require(options.last)
        #expect(await GitWorkflow.push(branch: feature, remote: target.remote, force: false,
                                       destinationRef: target.ref, setUpstream: false, at: repo.path) == nil)
        let published = await GitRepositoryLoader.snapshot(at: repo.path)
        #expect(published.localBranches.first { $0.name == feature.name }?.upstream == nil)
        #expect(published.pushDestinations(for: feature).allSatisfy { !$0.isNew })
        #expect(await GitRepositoryLoader.branches(at: remote.path).local.contains { $0.name == feature.name })
        #expect(await GitWorkflow.push(branch: feature, remote: target.remote, force: false,
                                       destinationRef: "refs/heads/aaa", setUpstream: true, at: repo.path) == nil)
        let tracked = await GitRepositoryLoader.snapshot(at: repo.path)
        #expect(tracked.currentBranch == "main")
        #expect(tracked.localBranches.first { $0.name == feature.name }?.upstream == "team/backup/aaa")
    }

    @Test("Working tree, index and commit report independent file line counts")
    func fileLineChanges() async throws {
        let repo = try makeRepo(commits: ["base"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Sources/nested.txt"
        try FileManager.default.createDirectory(at: repo.appending(path: "Sources"), withIntermediateDirectories: true)
        let url = repo.appending(path: path)
        try Data("first\nsecond".utf8).write(to: url)
        #expect(await GitRepositoryLoader.untrackedLineChanges(for: url.path, at: repo.path) == .text(added: 2, deleted: 0))
        try git(["add", "--", path], at: repo)
        try Data("first\nthird\nfourth\n".utf8).write(to: url)
        #expect(await GitRepositoryLoader.workingLineChanges(staged: true, at: repo.path)[path] == .text(added: 2, deleted: 0))
        #expect(await GitRepositoryLoader.workingLineChanges(staged: false, at: repo.path)[path] == .text(added: 2, deleted: 1))
        try git(["commit", "-qm", "add file"], at: repo)
        let commit = try #require(await GitRepositoryLoader.history(at: repo.path, ref: "HEAD", limit: 1).first)
        #expect(await GitRepositoryLoader.files(in: commit, at: repo.path).first?.lineChanges == .text(added: 2, deleted: 0))
        let binary = repo.appending(path: "binary")
        try Data([0, 1, 2]).write(to: binary)
        #expect(await GitRepositoryLoader.untrackedLineChanges(for: binary.path, at: repo.path) == .binary)
    }

    @Test("Staging and unstaging a folder affect only the listed changes under that folder")
    func stageSelectedFolder() async throws {
        let repo = try makeRepo(commits: ["base"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let paths = ["App/Views/nested.txt", "App/top.txt", "AppTests/test.txt"]
        for path in paths {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("added\n".utf8).write(to: url)
        }
        let selected = GitPathTree(paths: paths).filePaths(in: ["App/", "App/Views/nested.txt"])
        #expect(await GitHelper.stage(paths: selected, at: repo.path) == nil)
        #expect(Set(await GitRepositoryLoader.workingLineChanges(staged: true, at: repo.path).keys) == ["App/Views/nested.txt", "App/top.txt"])
        #expect(await GitHelper.unstage(paths: selected, at: repo.path) == nil)
        #expect(await GitRepositoryLoader.workingLineChanges(staged: true, at: repo.path).isEmpty)
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: repo.appending(path: $0).path) })
    }

    @Test("Branch deletion targets the selected remote head and preserves same-named tags")
    func deleteLocalAndRemoteBranch() async throws {
        let repo = try makeRepo(commits: ["one"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let remote = try addRemote("team/backup", to: repo)
        _ = try addRemote("origin", to: repo)
        try git(["branch", "topic"], at: repo)
        try git(["tag", "review/topic"], at: repo)
        try git(["push", "origin", "refs/heads/topic"], at: repo)
        try git(["push", "-u", "team/backup", "refs/heads/topic:refs/heads/review/topic", "refs/tags/review/topic"], at: repo)

        let snapshot = await GitRepositoryLoader.snapshot(at: repo.path)
        let local = try #require(snapshot.localBranches.first { $0.name == "topic" })
        let targets = snapshot.remoteBranches(for: local)
        #expect(targets.map(\.refName) == ["team/backup/review/topic"])
        let target = try #require(targets.first)
        #expect(await GitWorkflow.deleteBranch(local, alsoDelete: target, at: repo.path) == nil)

        let remaining = await GitRepositoryLoader.snapshot(at: repo.path)
        #expect(remaining.localBranches.map(\.name) == ["main"])
        #expect(remaining.remoteBranches.map(\.refName) == ["origin/topic"])
        let server = await GitRepositoryLoader.snapshot(at: remote.path)
        #expect(server.localBranches.isEmpty)
        #expect(server.tags.map(\.name) == ["review/topic"])
    }

    @Test("Local-only deletion preserves published branches on every remote")
    func deleteWithoutUpstream() async throws {
        let repo = try makeRepo(commits: ["one"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["branch", "topic"], at: repo)
        for remote in ["origin", "fork"] {
            _ = try addRemote(remote, to: repo)
            try git(["push", remote, "refs/heads/topic"], at: repo)
        }
        let snapshot = await GitRepositoryLoader.snapshot(at: repo.path)
        let local = try #require(snapshot.localBranches.first { $0.name == "topic" })
        #expect(Set(snapshot.remoteBranches(for: local).map(\.refName)) == ["origin/topic", "fork/topic"])
        #expect(await GitWorkflow.deleteBranch(local, alsoDelete: nil, at: repo.path) == nil)
        #expect(await GitRepositoryLoader.snapshot(at: repo.path).remoteBranches == snapshot.remoteBranches)
    }

    @Test("A checked-out branch or a moved remote tip prevents combined deletion")
    func rejectedDeletionKeepsBothBranches() async throws {
        let repo = try makeRepo(commits: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let origin = try addRemote("origin", to: repo)
        try git(["push", "origin", "HEAD:refs/heads/main", "HEAD^:refs/heads/topic"], at: repo)
        try git(["branch", "--track", "topic", "origin/topic"], at: repo)
        let snapshot = await GitRepositoryLoader.snapshot(at: repo.path)
        let local = try #require(snapshot.localBranches.first { $0.name == "topic" })
        let target = try #require(snapshot.remoteBranches(for: local).first)

        let worktree = repo.appending(path: ".git/other-checkout")
        try git(["worktree", "add", worktree.path, "topic"], at: repo)
        #expect(await GitWorkflow.deleteBranch(local, alsoDelete: target, at: repo.path) != nil)
        #expect(await GitRepositoryLoader.snapshot(at: origin.path).localBranches.contains { $0.name == "topic" })
        try git(["worktree", "remove", worktree.path], at: repo)

        try git(["update-ref", "refs/heads/topic", "refs/heads/main"], at: origin)
        #expect(await GitWorkflow.deleteBranch(local, alsoDelete: target, at: repo.path) != nil)
        #expect(await GitRepositoryLoader.snapshot(at: repo.path).localBranches.contains(local))
        #expect(await GitRepositoryLoader.snapshot(at: origin.path).localBranches.first { $0.name == "topic" }?.tip == snapshot.headCommit)
    }

    @Test("A background fetch updates the pull count without changing the checkout or FETCH_HEAD")
    func fetchIncomingCommits() async throws {
        let repo = try makeRepo(commits: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let origin = try addRemote("origin", to: repo)
        try git(["push", "origin", "HEAD:refs/heads/main", "HEAD^:refs/heads/topic"], at: repo)
        try git(["fetch", "origin", "main"], at: repo)
        let fetchHead = repo.appending(path: ".git/FETCH_HEAD")
        let previousFetch = try Data(contentsOf: fetchHead)
        let refs = await GitRepositoryLoader.snapshot(at: repo.path)
        let topic = try #require(refs.remoteBranches.first { $0.name == "topic" })
        #expect(await GitWorkflow.checkout(remote: topic, localBranches: refs.localBranches, at: repo.path) == nil)
        try git(["update-ref", "refs/heads/topic", "refs/heads/main"], at: origin)
        #expect(await GitWorkflow.fetch(at: repo.path, inBackground: true) == nil)
        let fetched = try #require(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch)
        #expect(fetched.name == "topic" && fetched.tip == topic.tip && fetched.behind == 1)
        #expect(try Data(contentsOf: fetchHead) == previousFetch)
        #expect(await GitWorkflow.pull(.fastForwardOnly, at: repo.path) == nil)
        #expect(await GitRepositoryLoader.snapshot(at: repo.path).currentLocalBranch?.behind == 0)
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

    @Test("Amend takes staged changes and preserves the original message and unstaged edits")
    func amendStagedChanges() async throws {
        let message = "two\ncontinued subject\n\nBody\n\nSigned-off-by: Test <test@example.com>"
        let repo = try makeRepo(commits: ["one", message])
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try #require(await GitHelper.headCommit(at: repo.path))
        #expect(await GitRepositoryLoader.commitMessage(for: head, at: repo.path) == message + "\n")

        let file = repo.appendingPathComponent("file1.txt")
        try Data("staged\n".utf8).write(to: file)
        try git(["add", "file1.txt"], at: repo)
        try Data("unstaged\n".utf8).write(to: file)
        try Data("untracked\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))

        #expect(await GitWorkflow.amend(message: nil, replacing: head, on: "main", at: repo.path) == nil)
        let amended = try #require(await GitHelper.headCommit(at: repo.path))
        #expect(amended != head)
        #expect(await GitRepositoryLoader.commitMessage(for: amended, at: repo.path) == message + "\n")
        #expect(await GitHelper.run(["show", "HEAD:file1.txt"], at: repo.path) == "staged\n")
        #expect(await GitHelper.run(["status", "--porcelain"], at: repo.path) == " M file1.txt\n?? untracked.txt\n")
        #expect(await GitHelper.run(["rev-parse", "HEAD^"], at: repo.path) == GitHelper.run(["rev-parse", "\(head)^"], at: repo.path))
    }

    @Test("A clean amend can replace the message of an empty commit")
    func amendMessageOnCleanTree() async throws {
        let repo = try makeRepo(commits: ["one"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["commit", "--allow-empty", "--quiet", "-m", "two"], at: repo)
        let head = try #require(await GitHelper.headCommit(at: repo.path))
        let tree = await GitHelper.run(["rev-parse", "HEAD^{tree}"], at: repo.path)

        #expect(await GitWorkflow.amend(message: "New subject\n\nNew body", replacing: head, on: "main", at: repo.path) == nil)
        let amended = try #require(await GitHelper.headCommit(at: repo.path))
        #expect(amended != head)
        #expect(await GitRepositoryLoader.commitMessage(for: amended, at: repo.path) == "New subject\n\nNew body\n")
        #expect(await subjects(at: repo) == ["New subject", "one"])
        #expect(await GitHelper.run(["rev-parse", "HEAD^{tree}"], at: repo.path) == tree)
        #expect(await GitHelper.run(["status", "--porcelain"], at: repo.path) == "")
    }

    @Test("Amend rejects a different branch and a newer commit")
    func amendRejectsChangedCheckout() async throws {
        let repo = try makeRepo(commits: ["one"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try #require(await GitHelper.headCommit(at: repo.path))
        try git(["switch", "-c", "other"], at: repo)

        #expect(await GitWorkflow.amend(message: "Wrong branch", replacing: head, on: "main", at: repo.path) != nil)
        #expect(await GitHelper.headCommit(at: repo.path) == head)

        try git(["switch", "main"], at: repo)
        try git(["commit", "--allow-empty", "--quiet", "-m", "two"], at: repo)
        let latest = try #require(await GitHelper.headCommit(at: repo.path))
        #expect(await GitWorkflow.amend(message: "Wrong commit", replacing: head, on: "main", at: repo.path) != nil)
        #expect(await GitHelper.headCommit(at: repo.path) == latest)
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
