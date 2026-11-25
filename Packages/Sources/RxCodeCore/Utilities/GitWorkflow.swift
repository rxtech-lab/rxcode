import Foundation

#if os(macOS)
public struct GitPushDestination: Hashable, Sendable {
    public let remote: String
    public let ref: String
    public let isNew: Bool

    public var branch: String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref }
    public var displayName: String { "\(remote)/\(branch)" }
}

public struct GitBranchList: Sendable {
    public var local: [GitLocalBranch] = []
    public var remote: [GitRemoteBranch] = []
    public var remotes: [String] = []

    public init() {}
}

/// Snapshot of refs and repository state shown by the Git workflow window.
public struct GitRepositorySnapshot: Equatable, Sendable {
    public var currentBranch: String?
    public var headCommit: String?
    public var localBranches: [GitLocalBranch] = []
    public var remoteBranches: [GitRemoteBranch] = []
    public var remotes: [String] = []
    public var tags: [GitTag] = []
    public var stashes: [GitStash] = []
    public var pendingOperation: GitPendingOperation?

    public init() {}

    public var currentLocalBranch: GitLocalBranch? {
        localBranches.first { $0.isCurrent }
    }

    public func pushDestinations(for branch: GitLocalBranch) -> [GitPushDestination] {
        var destinations = remoteBranches.map {
            GitPushDestination(remote: $0.remote, ref: "refs/heads/\($0.name)", isNew: false)
        }
        for remote in remotes {
            let ref = branch.pushDestination(on: remote)
            if !destinations.contains(where: { $0.remote == remote && $0.ref == ref }) {
                destinations.append(GitPushDestination(remote: remote, ref: ref, isNew: true))
            }
        }
        return GitBranchOrder.primaryFirst(destinations, by: \.branch)
    }

    /// Prefer the configured upstream, which can have a different name on the
    /// server. An unpublished local branch can also have same-named remote refs.
    public func remoteBranches(for branch: GitLocalBranch) -> [GitRemoteBranch] {
        guard let remote = branch.upstreamRemote else {
            return remoteBranches.filter { $0.name == branch.name }
        }
        guard remotes.contains(remote), let ref = branch.upstreamRef, ref.hasPrefix("refs/heads/"),
              let tracking = remoteBranches.first(where: { $0.refName == branch.upstream }) else { return [] }
        return [GitRemoteBranch(remote: remote, name: String(ref.dropFirst("refs/heads/".count)), tip: tracking.tip)]
    }
}

/// Read-only queries for the Git workflow window.
public enum GitRepositoryLoader {
    static let branchFormat = "--format=%(refname:lstrip=2)%1f%(upstream:lstrip=2)%1f%(HEAD)%1f%(upstream:track)%1f%(objectname)%1f%(upstream:remotename)%1f%(upstream:remoteref)"

    public static func snapshot(at root: String) async -> GitRepositorySnapshot {
        async let branch = GitHelper.currentBranch(at: root)
        async let head = GitHelper.headCommit(at: root)
        async let branchList = branches(at: root)
        async let tagRefs = GitHelper.run(
            ["for-each-ref", "--sort=-creatordate", "--format=%(refname:lstrip=2)%1f%(objectname)%1f%(*objectname)", "refs/tags"],
            at: root
        )
        async let stashList = GitHelper.run(["stash", "list", "--format=%gd%x1f%s%x1f%H"], at: root)
        async let pending = pendingOperation(at: root)

        var snapshot = GitRepositorySnapshot()
        snapshot.currentBranch = await branch
        snapshot.headCommit = await head
        let refs = await branchList
        snapshot.localBranches = refs.local
        snapshot.remoteBranches = refs.remote
        snapshot.remotes = refs.remotes
        snapshot.tags = (await tagRefs ?? "").split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return GitTag(name: fields[0], tip: fields[2].isEmpty ? fields[1] : fields[2])
        }
        snapshot.stashes = (await stashList ?? "").split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }
            return GitStash(selector: fields[0], message: fields[1], tip: fields[2])
        }
        snapshot.pendingOperation = await pending
        return snapshot
    }

    public static func branches(at root: String) async -> GitBranchList {
        async let locals = GitHelper.run(["for-each-ref", branchFormat, "refs/heads"], at: root, environment: ["LC_ALL": "C"])
        async let refs = GitHelper.run(["for-each-ref", "--format=%(refname)%1f%(objectname)%1f%(symref)", "refs/remotes"], at: root)
        async let names = GitHelper.run(["remote"], at: root)
        var list = GitBranchList()
        list.remotes = (await names ?? "").split(separator: "\n").map(String.init)
        list.local = GitBranchOrder.primaryFirst(GitHistoryParser.parseLocalBranches(await locals ?? ""), by: \.name)
        // A configured remote name can itself contain slashes.
        let prefixes = list.remotes.sorted { $0.count > $1.count }
        let remoteBranches = (await refs ?? "").split(separator: "\n").compactMap { line -> GitRemoteBranch? in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[2].isEmpty, fields[0].hasPrefix("refs/remotes/") else { return nil }
            let ref = fields[0].dropFirst("refs/remotes/".count)
            guard let remote = prefixes.first(where: { ref.hasPrefix($0 + "/") }) else { return nil }
            return GitRemoteBranch(remote: remote, name: String(ref.dropFirst(remote.count + 1)), tip: fields[1])
        }
        .sorted { $0.refName.localizedStandardCompare($1.refName) == .orderedAscending }
        list.remote = GitBranchOrder.primaryFirst(remoteBranches, by: \.name)
        return list
    }

    public static func pendingOperation(at root: String) async -> GitPendingOperation? {
        guard let raw = await GitHelper.run(["rev-parse", "--absolute-git-dir"], at: root) else { return nil }
        let gitDirectory = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for operation in GitPendingOperation.allCases {
            for marker in operation.markers
            where FileManager.default.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(marker)) {
                return operation
            }
        }
        return nil
    }

    /// Commits reachable from branches, remote branches, tags, and HEAD, newest first.
    /// `ref` limits the history to one branch or commit.
    public static func history(at root: String, ref: String? = nil, limit: Int) async -> [GitCommit] {
        var args = ["log", "--topo-order", "--decorate=full", GitHistoryParser.logFormat, "--max-count=\(limit)"]
        if let ref {
            args += [ref, "--"]
        } else {
            args += ["--branches", "--remotes", "--tags", "HEAD", "--"]
        }
        guard let raw = await GitHelper.run(args, at: root) else { return [] }
        return GitHistoryParser.parseLog(raw)
    }

    public static func commitMessage(for commit: String, at root: String) async -> String? {
        await GitHelper.run(["log", "-1", "--encoding=UTF-8", "--format=format:%B", "--end-of-options", commit, "--"], at: root)
    }

    /// Commits after `base` up to HEAD, oldest first. A nil base lists the whole branch.
    public static func commitsSince(_ base: String?, at root: String) async -> [GitCommit]? {
        let range = base.map { "\($0)..HEAD" } ?? "HEAD"
        guard let raw = await GitHelper.run(["log", "--reverse", "--topo-order", GitHistoryParser.logFormat, range, "--"], at: root) else {
            return nil
        }
        return GitHistoryParser.parseLog(raw)
    }

    public static func isAncestor(_ commit: String, of descendant: String = "HEAD", at root: String) async -> Bool {
        await GitHelper.execute(["merge-base", "--is-ancestor", commit, descendant], at: root)?.status == 0
    }

    /// Files a commit changed relative to its first parent (or the empty tree for root commits).
    public static func files(in commit: GitCommit, at root: String) async -> [GitCommitFile] {
        let args = ["diff-tree", "-r", "-M", "-z", "--no-commit-id"]
        let range = [commit.parents.first ?? "--root", commit.id, "--"]
        async let names = GitHelper.run(args + ["--name-status"] + range, at: root)
        async let counts = GitHelper.run(args + ["--numstat"] + range, at: root)
        return GitHistoryParser.parseNameStatus(await names ?? "", lineChanges: GitLineChanges.parseNumstat(await counts ?? ""))
    }

    public static func workingLineChanges(staged: Bool, at root: String) async -> [String: GitLineChanges] {
        let args = ["--no-optional-locks", "diff", "--no-ext-diff", "--numstat", "-z", "-M"]
        let raw = await GitHelper.run(args + (staged ? ["--cached"] : []) + ["--"], at: root)
        return GitLineChanges.parseNumstat(raw ?? "")
    }

    public static func untrackedLineChanges(for path: String, at root: String) async -> GitLineChanges? {
        let args = ["diff", "--no-index", "--no-ext-diff", "--numstat", "-z", "--", "/dev/null", path]
        guard let output = await GitHelper.execute(args, at: root), output.status == 0 || output.status == 1 else { return nil }
        return GitLineChanges.parseNumstat(String(decoding: output.stdout, as: UTF8.self))[path]
    }

    public static func trackedPaths(in commit: GitCommit, at root: String) async -> [String] {
        let raw = await GitHelper.run(["ls-tree", "-r", "-z", "--name-only", "--full-tree", commit.id], at: root)
        return (raw ?? "").split(separator: "\0").map(String.init)
    }

    public static func fileText(at path: String, in commit: GitCommit, root: String) async -> String? {
        let object = "\(commit.id):\(path)"
        guard let rawSize = await GitHelper.run(["cat-file", "-s", object], at: root),
              let size = Int(rawSize.trimmingCharacters(in: .newlines)), size <= 256 * 1024,
              let text = await GitHelper.run(["cat-file", "blob", object], at: root),
              !text.contains("\0") else { return nil }
        return text
    }

    public static func fileData(
        at path: String,
        in commit: GitCommit,
        root: String,
        maxBytes: Int = 20 * 1024 * 1024
    ) async -> Data? {
        let object = "\(commit.id):\(path)"
        guard let rawSize = await GitHelper.run(["cat-file", "-s", object], at: root),
              let size = Int(rawSize.trimmingCharacters(in: .newlines)),
              size <= maxBytes,
              let output = await GitHelper.execute(["cat-file", "blob", object], at: root),
              output.status == 0 else { return nil }
        return output.stdout
    }

    public static func diff(of file: GitCommitFile, in commit: GitCommit, at root: String) async -> String {
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        if let parent = commit.parents.first {
            return await GitHelper.run(["diff", "--no-color", "-M", parent, commit.id, "--"] + paths, at: root) ?? ""
        }
        return await GitHelper.run(["show", "--no-color", "--format=", commit.id, "--"] + paths, at: root) ?? ""
    }

    public static func stashDiff(_ stash: GitStash, at root: String) async -> String {
        if let diff = await GitHelper.run(["stash", "show", "--no-color", "-p", "--include-untracked", stash.selector], at: root) {
            return diff
        }
        return await GitHelper.run(["stash", "show", "--no-color", "-p", stash.selector], at: root) ?? ""
    }
}

/// Mutating Git commands for the workflow window. Every call returns nil on
/// success or git's combined output on failure. None of them open an editor.
public enum GitWorkflow {
    /// Prevents git from blocking on an interactive editor.
    static let nonInteractive = ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"]

    public enum ResetMode: String, CaseIterable, Sendable {
        case soft, mixed, hard
    }

    public enum PullStrategy: Sendable {
        case fastForwardOnly, merge, rebase
    }

    public static func fetch(at root: String, inBackground: Bool = false) async -> String? {
        var arguments = ["fetch", "--all", "--prune", "--tags"]
        // A foreground pull owns FETCH_HEAD. Polling only needs the updated refs.
        if inBackground { arguments.append("--no-write-fetch-head") }
        let environment = inBackground ? ["GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS_REQUIRE": "never", "GCM_INTERACTIVE": "never"] : [:]
        return await GitHelper.runWithError(arguments, at: root, environment: environment)
    }

    public static func pull(_ strategy: PullStrategy, at root: String) async -> String? {
        let flag = switch strategy {
        case .fastForwardOnly: "--ff-only"
        case .merge: "--no-rebase"
        case .rebase: "--rebase"
        }
        return await GitHelper.runWithError(["pull", flag], at: root, environment: nonInteractive)
    }

    public static func push(
        branch: GitLocalBranch,
        remote: String,
        force: Bool,
        pushAllTags: Bool = false,
        destinationRef: String? = nil,
        setUpstream: Bool? = nil,
        at root: String
    ) async -> String? {
        let destination = destinationRef ?? branch.pushDestination(on: remote)
        var options: [String] = []
        if setUpstream ?? (branch.upstream == nil) { options.append("--set-upstream") }
        // Scope the lease to the branch when the same push also includes tags.
        if force { options.append("--force-with-lease=\(destination)") }
        if pushAllTags { options.append("--tags") }
        return await push("\(branch.refName):\(destination)", to: remote, options: options, at: root)
    }

    public static func checkout(_ ref: String, at root: String) async -> String? {
        await GitHelper.runWithError(["switch", "--", ref], at: root)
    }

    public static func checkoutDetached(_ commit: String, at root: String) async -> String? {
        await GitHelper.runWithError(["switch", "--detach", commit], at: root)
    }

    public static func checkout(remote branch: GitRemoteBranch, localBranches: [GitLocalBranch], at root: String) async -> String? {
        let trackingRef = "refs/remotes/\(branch.refName)"
        if localBranches.contains(where: { $0.name == branch.name }) {
            if let failure = await checkout(branch.name, at: root) { return failure }
            return await GitHelper.runWithError(["branch", "--set-upstream-to", trackingRef, "--", branch.name], at: root)
        }
        return await GitHelper.runWithError(["switch", "--track", "-c", branch.name, trackingRef], at: root)
    }

    public static func createBranch(_ name: String, at startPoint: String, checkout: Bool, root: String) async -> String? {
        if checkout {
            return await GitHelper.runWithError(["switch", "-c", name, startPoint], at: root)
        }
        return await GitHelper.runWithError(["branch", "--", name, startPoint], at: root)
    }

    public static func renameBranch(_ name: String, to newName: String, at root: String) async -> String? {
        await GitHelper.runWithError(["branch", "-m", "--", name, newName], at: root)
    }

    public static func deleteBranch(_ name: String, force: Bool, at root: String) async -> String? {
        await GitHelper.runWithError(["branch", force ? "-D" : "-d", "--", name], at: root)
    }

    public static func deleteBranch(_ branch: GitLocalBranch, alsoDelete remote: GitRemoteBranch?, at root: String) async -> String? {
        if let remote {
            // Check every worktree before removing the server's copy. Keep the
            // local copy if the server rejects the deletion.
            let state = await GitHelper.run(
                ["for-each-ref", "--format=%(refname)%1f%(objectname)%1f%(worktreepath)", branch.refName], at: root
            )
            guard state == "\(branch.refName)\u{1F}\(branch.tip)\u{1F}\n" else {
                return String(localized: "The local branch “\(branch.name)” has changed or is checked out in a worktree.")
            }
            if let failure = await deleteRemoteBranch(remote, at: root) { return failure }
        }
        let failure = await deleteBranch(branch.name, force: true, at: root)
        if let failure, let remote {
            return String(localized: "Deleted “\(remote.refName)” from the remote. Git could not delete the local branch “\(branch.name)”.\n\n\(failure)")
        }
        return failure
    }

    public static func deleteRemoteBranch(_ branch: GitRemoteBranch, at root: String) async -> String? {
        let ref = "refs/heads/\(branch.name)"
        return await push(":\(ref)", to: branch.remote, options: ["--force-with-lease=\(ref):\(branch.tip)"], at: root)
    }

    public static func merge(_ ref: String, noFastForward: Bool, at root: String) async -> String? {
        var args = ["merge", "--no-edit"]
        if noFastForward { args.append("--no-ff") }
        args.append(ref)
        return await GitHelper.runWithError(args, at: root, environment: nonInteractive)
    }

    public static func rebase(onto ref: String, at root: String) async -> String? {
        await GitHelper.runWithError(["rebase", "--autostash", ref], at: root, environment: nonInteractive)
    }

    public static func cherryPick(_ commit: String, at root: String) async -> String? {
        await GitHelper.runWithError(["cherry-pick", commit], at: root, environment: nonInteractive)
    }

    public static func revert(_ commit: GitCommit, at root: String) async -> String? {
        var args = ["revert", "--no-edit"]
        if commit.isMerge { args += ["-m", "1"] }
        args.append(commit.id)
        return await GitHelper.runWithError(args, at: root, environment: nonInteractive)
    }

    public static func reset(to commit: String, mode: ResetMode, at root: String) async -> String? {
        await GitHelper.runWithError(["reset", "--\(mode.rawValue)", commit], at: root)
    }

    public static func createTag(_ name: String, at commit: String, message: String?, root: String) async -> String? {
        var args = ["tag"]
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-a", "-m", message]
        }
        args += ["--", name, commit]
        return await GitHelper.runWithError(args, at: root)
    }

    public static func deleteTag(_ name: String, at root: String) async -> String? {
        await GitHelper.runWithError(["tag", "-d", "--", name], at: root)
    }

    public static func pushTag(_ name: String, remote: String, at root: String) async -> String? {
        await push("refs/tags/\(name)", to: remote, at: root)
    }

    private static func push(_ refspec: String, to remote: String, options: [String] = [], at root: String) async -> String? {
        guard await GitHelper.run(["remote", "get-url", "--push", "--", remote], at: root) != nil else {
            return String(localized: "The remote “\(remote)” is unavailable.")
        }
        return await GitHelper.runWithError(["push"] + options + ["--", remote, refspec], at: root)
    }

    public static func stash(message: String, includeUntracked: Bool, at root: String) async -> String? {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += ["-m", trimmed] }
        return await GitHelper.runWithError(args, at: root)
    }

    public static func applyStash(_ stash: GitStash, pop: Bool, at root: String) async -> String? {
        await GitHelper.runWithError(["stash", pop ? "pop" : "apply", stash.selector], at: root)
    }

    public static func dropStash(_ stash: GitStash, at root: String) async -> String? {
        await GitHelper.runWithError(["stash", "drop", stash.selector], at: root)
    }

    public static func discard(paths: [String], untracked: Bool, at root: String) async -> String? {
        guard !paths.isEmpty else { return nil }
        if untracked {
            return await GitHelper.runWithError(["--literal-pathspecs", "clean", "-f", "--"] + paths, at: root)
        }
        return await GitHelper.runWithError(["--literal-pathspecs", "restore", "--worktree", "--"] + paths, at: root)
    }

    public static func addRemote(name: String, url: String, at root: String) async -> String? {
        await GitHelper.runWithError(["remote", "add", "--", name, url], at: root)
    }

    public static func removeRemote(_ name: String, at root: String) async -> String? {
        await GitHelper.runWithError(["remote", "remove", name], at: root)
    }

    public enum Continuation: String, Sendable {
        case `continue`, abort, skip
    }

    public static func resolve(_ operation: GitPendingOperation, _ action: Continuation, at root: String) async -> String? {
        await GitHelper.runWithError([operation.command, "--\(action.rawValue)"], at: root, environment: nonInteractive)
    }

    /// Replaces the checked-out commit using the current index. A nil message keeps the original.
    public static func amend(message: String?, replacing commit: String, on branch: String?, at root: String) async -> String? {
        async let head = GitHelper.headCommit(at: root)
        async let currentBranch = GitHelper.currentBranch(at: root)
        async let pending = GitRepositoryLoader.pendingOperation(at: root)
        let (checkedOutCommit, checkedOutBranch, pendingOperation) = await (head, currentBranch, pending)
        guard checkedOutCommit == commit, checkedOutBranch == branch else {
            return String(localized: "The checkout changed. Open Amend Commit again.")
        }
        guard pendingOperation == nil else {
            return String(localized: "Finish the current Git operation before amending the commit.")
        }

        let args = ["commit", "--amend", "--allow-empty"]
        guard let message else {
            return await GitHelper.runWithError(
                args + ["--no-edit", "--cleanup=verbatim", "--allow-empty-message"], at: root, environment: nonInteractive
            )
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Empty commit message") }
        return await withTemporaryFile(trimmed) { path in
            await GitHelper.runWithError(args + ["-F", path], at: root, environment: nonInteractive)
        }
    }

    /// Rewrites one commit message. HEAD is amended directly; older commits go
    /// through a non-interactive rebase that rewords only that commit.
    public static func reword(_ commit: GitCommit, message: String, at root: String) async -> String? {
        if await GitHelper.headCommit(at: root) == commit.id {
            return await withTemporaryFile(message) { path in
                await GitHelper.runWithError(
                    ["commit", "--amend", "--allow-empty", "--only", "--cleanup=strip", "-F", path],
                    at: root,
                    environment: nonInteractive
                )
            }
        }
        guard let steps = await rebaseSteps(from: commit, at: root) else {
            return String(localized: "Only commits on the current branch can be reworded.")
        }
        let edited = steps.map { step in
            var step = step
            if step.commit == commit.id {
                step.action = .reword
                step.message = message
            }
            return step
        }
        return await interactiveRebase(edited, base: commit.parents.first, at: root)
    }

    /// Lists the commits from `commit` through HEAD as rebase steps, oldest
    /// first. Returns nil when `commit` isn't on the current branch or the
    /// range contains merge commits, which a linear rebase would flatten.
    public static func rebaseSteps(from commit: GitCommit, at root: String) async -> [GitRebaseStep]? {
        guard await GitRepositoryLoader.isAncestor(commit.id, at: root),
              let commits = await GitRepositoryLoader.commitsSince(commit.parents.first, at: root),
              !commits.contains(where: \.isMerge) else { return nil }
        return commits.map { GitRebaseStep(commit: $0.id, subject: $0.subject, message: $0.fullMessage) }
    }

    /// Runs `git rebase -i` with a prepared todo list. A nil base rebases from the root commit.
    public static func interactiveRebase(_ steps: [GitRebaseStep], base: String?, at root: String) async -> String? {
        if let invalid = GitRebasePlan.validate(steps) {
            switch invalid {
            case .empty: return String(localized: "Keep at least one commit in the rebase.")
            case .squashWithoutTarget: return String(localized: "The first kept commit can’t be squashed or fixed up.")
            case .emptyRewordMessage: return String(localized: "Reworded commits need a message.")
            }
        }
        // Left in place while the rebase is paused: the reword `exec` lines still
        // read their message files after the user continues.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rxcode-rebase-\(UUID().uuidString)")
        let todoURL = directory.appendingPathComponent("todo")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [String: String] = [:]
            for (index, step) in steps.enumerated() where step.action == .reword {
                let url = directory.appendingPathComponent("message-\(index).txt")
                try step.message.write(to: url, atomically: true, encoding: .utf8)
                files[step.commit] = url.path
            }
            try GitRebasePlan.todo(for: steps) { files[$0.commit] ?? "" }.write(to: todoURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return error.localizedDescription
        }
        var environment = nonInteractive
        environment["GIT_SEQUENCE_EDITOR"] = "cp \(GitRebasePlan.shellQuoted(todoURL.path))"
        let result = await GitHelper.runWithError(["rebase", "-i", "--autostash", base ?? "--root"], at: root, environment: environment)
        if await GitRepositoryLoader.pendingOperation(at: root) != .rebase {
            try? FileManager.default.removeItem(at: directory)
        }
        return result
    }

    private static func withTemporaryFile(_ contents: String, body: (String) async -> String?) async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rxcode-message-\(UUID().uuidString).txt")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return await body(url.path)
    }
}
#endif
