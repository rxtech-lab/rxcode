import Foundation

#if os(macOS)
public enum GitHelper {
    /// Environment for `/usr/bin/git` subprocesses. Augments PATH with the
    /// standard Homebrew and system bin directories so git can locate
    /// auxiliary tools (gpg for signed commits, ssh, credential helpers, etc.)
    /// even when the app's inherited PATH is sparse.
    private static func gitEnvironment() -> [String: String] {
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        let existingSegments = existingPath.split(separator: ":").map(String.init)
        var merged = existingSegments
        for p in extraPaths where !merged.contains(p) {
            merged.append(p)
        }
        env["PATH"] = merged.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = ""
        env["PAGER"] = ""
        return env
    }

    /// Captured result of a finished git subprocess.
    struct ProcessOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var combinedTrimmed: String {
            let combined = (String(data: stdout, encoding: .utf8) ?? "") +
                (String(data: stderr, encoding: .utf8) ?? "")
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs `/usr/bin/git` off the caller's executor and drains stdout/stderr
    /// *concurrently* with the process (and feeds `input` on its own thread).
    ///
    /// Waiting for exit before reading is a deadlock: once git writes more than
    /// the 64 KB pipe buffer (a large `git status --untracked-files=all`,
    /// `git diff`, or `check-ignore` over many paths) it blocks on write and
    /// never exits, so the await never returns — which wedged every caller
    /// queued behind it (e.g. the workspace change tracker actor, and with it
    /// every new agent stream in that workspace).
    static func execute(
        _ args: [String],
        at path: String,
        input: Data? = nil,
        environment overrides: [String: String] = [:]
    ) async -> ProcessOutput? {
        let environment = gitEnvironment().merging(overrides) { _, override in override }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executeBlocking(args, at: path, environment: environment, input: input))
            }
        }
    }

    private static func executeBlocking(
        _ args: [String],
        at path: String,
        environment: [String: String],
        input: Data?
    ) -> ProcessOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = input == nil ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let inPipe {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        let out = DataBox()
        let err = DataBox()
        let readQueue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        readQueue.async {
            out.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        readQueue.async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let inPipe, let input {
            readQueue.async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        group.wait()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, stdout: out.data, stderr: err.data)
    }

    public static func run(_ args: [String], at path: String, environment: [String: String] = [:]) async -> String? {
        guard let output = await execute(args, at: path, environment: environment), output.status == 0 else { return nil }
        return String(data: output.stdout, encoding: .utf8)
    }

    static func checkIgnoredPaths(_ paths: Set<String>, at gitRoot: String) async -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        let payload = Data((paths.joined(separator: "\0") + "\0").utf8)
        guard let output = await execute(["check-ignore", "-z", "--stdin"], at: gitRoot, input: payload),
              output.status == 0 || output.status == 1 else { return nil }
        return Set(String(decoding: output.stdout, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    /// Resolves the current ignore rules for absolute change paths in this worktree.
    public static func ignoredChangePaths(_ paths: Set<String>, at directory: String) async -> Set<String> {
        guard !paths.isEmpty,
              let rootOutput = await run(["rev-parse", "--show-toplevel"], at: directory) else { return [] }
        let rootPath = rootOutput.hasSuffix("\n") ? String(rootOutput.dropLast()) : rootOutput
        let gitRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = gitRoot.hasSuffix("/") ? gitRoot : gitRoot + "/"
        let byGitPath = Dictionary(grouping: paths) { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
        }
        let candidates = Set(byGitPath.keys.filter { $0.hasPrefix(prefix) })
        guard var ignored = await checkIgnoredPaths(candidates, at: gitRoot) else { return [] }

        // An absent path removed from the index represents a tracked deletion.
        let absent = ignored.filter { !FileManager.default.fileExists(atPath: $0) }
        if !absent.isEmpty,
           let deleted = await run(["diff", "--cached", "--no-renames", "--diff-filter=D", "--name-only", "-z"], at: gitRoot) {
            ignored.subtract(deleted.split(separator: "\0").map { prefix + String($0) }.filter { absent.contains($0) })
        }
        return Set(ignored.flatMap { byGitPath[$0] ?? [] })
    }

    public static func currentBranch(at path: String) async -> String? {
        guard let result = await run(["symbolic-ref", "--short", "HEAD"], at: path) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the checked-out commit ID, or nil before the first commit.
    public static func headCommit(at path: String) async -> String? {
        await run(["rev-parse", "--verify", "--quiet", "HEAD"], at: path)?
            .trimmingCharacters(in: .newlines)
    }

    /// Runs `git init` at `path`. Returns nil on success or the combined git
    /// output on failure.
    public static func initRepository(at path: String) async -> String? {
        await runWithError(["init"], at: path)
    }

    /// Checks out an existing branch at `path`. Returns the combined git output
    /// on failure, or nil on success.
    public static func checkout(branch: String, at path: String) async -> String? {
        await runWithError(["checkout", branch], at: path)
    }

    /// Creates a new branch and checks it out (`git checkout -b <branch> [fromRef]`)
    /// at `path`. Returns the combined git output on failure, or nil on success.
    public static func createBranch(_ branch: String, at path: String, fromRef: String? = nil) async -> String? {
        var args = ["checkout", "-b", branch]
        if let fromRef, !fromRef.isEmpty { args.append(fromRef) }
        return await runWithError(args, at: path)
    }

    /// Stages the given paths (`git add --`). Returns nil on success or the
    /// combined output on failure.
    public static func stage(paths: [String], at repoPath: String) async -> String? {
        guard !paths.isEmpty else { return nil }
        return await runWithError(["--literal-pathspecs", "add", "--"] + paths, at: repoPath)
    }

    /// Omitting the revision also supports unstaging before the repository's first commit.
    public static func unstage(paths: [String], at repoPath: String) async -> String? {
        guard !paths.isEmpty else { return nil }
        return await runWithError(["--literal-pathspecs", "reset", "--"] + paths, at: repoPath)
    }

    /// Commits the staged index with the given message. Returns nil on success
    /// or the combined git output on failure.
    public static func commit(message: String, at repoPath: String) async -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty commit message" }
        return await runWithError(["commit", "-m", trimmed], at: repoPath)
    }

    /// Returns the staged diff (`git diff --cached`). Empty string when nothing
    /// is staged.
    public static func stagedDiff(at repoPath: String) async -> String {
        await run(["diff", "--cached", "--no-color"], at: repoPath) ?? ""
    }

    /// Returns the staged diff stat (`git diff --cached --stat`). Compact
    /// per-file summary of additions and deletions — safe to include even when
    /// the full diff is too large to send to a model.
    public static func stagedStat(at repoPath: String) async -> String {
        await run(["diff", "--cached", "--stat", "--no-color"], at: repoPath) ?? ""
    }

    /// Runs a git command and returns nil on success or combined stdout+stderr
    /// trimmed on non-zero exit.
    public static func runWithError(
        _ args: [String],
        at path: String,
        environment: [String: String] = [:]
    ) async -> String? {
        guard let output = await execute(args, at: path, environment: environment) else {
            return "Failed to launch git \(args.first ?? "")"
        }
        if output.status == 0 { return nil }
        let trimmed = output.combinedTrimmed
        return trimmed.isEmpty ? "git \(args.first ?? "") exited \(output.status)" : trimmed
    }

    /// Snapshot of the current branch's relationship to its upstream remote.
    public struct UpstreamStatus: Sendable, Equatable {
        public let branch: String
        /// Upstream ref short name, e.g. "origin/main". Nil when no upstream
        /// has been configured for this branch.
        public let upstream: String?
        /// Commits the local branch is ahead of the upstream by. Zero when no
        /// upstream is configured.
        public let ahead: Int
        /// Commits the local branch is behind the upstream by.
        public let behind: Int
        /// Configured remotes (e.g. ["origin"]).
        public let remotes: [String]
    }

    /// Inspects the current branch's relationship to its tracked upstream and
    /// the configured remotes. Returns nil when the repository can't be read.
    public static func upstreamStatus(at repoPath: String) async -> UpstreamStatus? {
        guard let branch = await currentBranch(at: repoPath) else { return nil }

        let upstreamRaw = await run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            at: repoPath
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = (upstreamRaw?.isEmpty == false) ? upstreamRaw : nil

        var ahead = 0
        var behind = 0
        if upstream != nil,
           let counts = await run(
               ["rev-list", "--left-right", "--count", "@{u}...HEAD"],
               at: repoPath
           )?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        let remotesRaw = await run(["remote"], at: repoPath) ?? ""
        let remotes = remotesRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return UpstreamStatus(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            remotes: remotes
        )
    }

    /// Pushes the current branch. When `setUpstream` is true (or no upstream is
    /// configured), runs `git push -u <remote> <branch>` to create and track a
    /// new remote branch. Returns nil on success or the combined output on
    /// failure.
    public static func push(
        at repoPath: String,
        remote: String = "origin",
        branch: String,
        setUpstream: Bool
    ) async -> String? {
        var args = ["push"]
        if setUpstream {
            args.append("-u")
            args.append(remote)
            args.append(branch)
        }
        return await runWithError(args, at: repoPath)
    }

    /// Lists main and master first, followed by other branches in most-recent-commit order.
    public static func listLocalBranches(at path: String) async -> [String] {
        guard let result = await run(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:lstrip=2)", "refs/heads/"],
            at: path
        ) else {
            return []
        }
        return GitBranchOrder.primaryFirst(result.split(separator: "\n").map(String.init), by: \.self)
    }

    // MARK: - Uncommitted changes

    /// Which side of the working tree an uncommitted change lives on.
    public enum GitChangeKind: Sendable {
        case staged
        case unstaged
        case untracked
    }

    /// One uncommitted file in the working tree, with its unified diff.
    public struct GitChange: Sendable {
        public let displayPath: String
        public let statusChar: String
        public let kind: GitChangeKind
        public let unifiedDiff: String
        public let truncated: Bool
    }

    /// Maximum number of diff lines kept per file before truncation.
    private static let maxDiffLines = 800

    /// Returns every uncommitted change in the working tree at `repoPath`:
    /// staged, unstaged, and untracked files, each with its unified diff. A
    /// file modified both in the index and the worktree yields two entries
    /// (one `.staged`, one `.unstaged`). Returns nil when `repoPath` is not a
    /// git repository.
    public static func uncommittedChanges(at repoPath: String) async -> [GitChange]? {
        guard let statusRaw = await run(
            ["status", "--porcelain=v1", "-z"],
            at: repoPath
        ) else {
            return nil
        }

        var changes: [GitChange] = []
        // Porcelain `-z` records are NUL-terminated; renames/copies append a
        // second NUL-terminated token for the original path.
        let tokens = statusRaw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < tokens.count {
            let entry = tokens[i]
            i += 1
            guard entry.count >= 3 else { continue }
            let chars = Array(entry)
            let indexChar = chars[0]    // staged side
            let worktreeChar = chars[1] // worktree side
            let displayPath = String(entry.dropFirst(3))

            let isUntracked = (indexChar == "?" && worktreeChar == "?")
            let isRename = indexChar == "R" || worktreeChar == "R"
            if isRename, i < tokens.count {
                i += 1 // skip the rename's original-path token
            }

            if isUntracked {
                let diff = await untrackedDiff(displayPath: displayPath, repoPath: repoPath)
                changes.append(GitChange(
                    displayPath: displayPath,
                    statusChar: "?",
                    kind: .untracked,
                    unifiedDiff: diff.text,
                    truncated: diff.truncated
                ))
            } else if worktreeChar != " " {
                let raw = await run(["diff", "--no-color", "--", displayPath], at: repoPath) ?? ""
                let clipped = clipDiff(raw)
                changes.append(GitChange(
                    displayPath: displayPath,
                    statusChar: String(worktreeChar),
                    kind: .unstaged,
                    unifiedDiff: clipped.text,
                    truncated: clipped.truncated
                ))
            }

            if !isUntracked, indexChar != " " {
                let raw = await run(["diff", "--cached", "--no-color", "--", displayPath], at: repoPath) ?? ""
                let clipped = clipDiff(raw)
                changes.append(GitChange(
                    displayPath: displayPath,
                    statusChar: String(indexChar),
                    kind: .staged,
                    unifiedDiff: clipped.text,
                    truncated: clipped.truncated
                ))
            }
        }
        return changes
    }

    /// Builds an all-added pseudo-diff for an untracked file by reading its
    /// contents. Binary or unreadable files yield an empty diff.
    private static func untrackedDiff(
        displayPath: String,
        repoPath: String
    ) async -> (text: String, truncated: Bool) {
        let absolute = (repoPath as NSString).appendingPathComponent(displayPath)
        guard let content = try? String(contentsOf: URL(fileURLWithPath: absolute), encoding: .utf8) else {
            return ("", false)
        }
        let lines = content.components(separatedBy: "\n")
        let capped = lines.count > maxDiffLines
        let kept = capped ? Array(lines.prefix(maxDiffLines)) : lines
        return (kept.map { "+" + $0 }.joined(separator: "\n"), capped)
    }

    /// Clips a unified diff to `maxDiffLines` lines.
    private static func clipDiff(_ diff: String) -> (text: String, truncated: Bool) {
        let lines = diff.components(separatedBy: "\n")
        guard lines.count > maxDiffLines else { return (diff, false) }
        return (lines.prefix(maxDiffLines).joined(separator: "\n"), true)
    }
}

#endif
