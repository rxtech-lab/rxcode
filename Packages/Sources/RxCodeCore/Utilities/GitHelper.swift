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

    public static func run(_ args: [String], at path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = gitEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func currentBranch(at path: String) async -> String? {
        guard let result = await run(["symbolic-ref", "--short", "HEAD"], at: path) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Checks out an existing branch at `path`. Returns the combined git output
    /// on failure, or nil on success.
    public static func checkout(branch: String, at path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", branch]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = gitEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch { return "\(error)" }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        if process.terminationStatus == 0 { return nil }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") +
                       (String(data: errData, encoding: .utf8) ?? "")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "git checkout exited \(process.terminationStatus)" : trimmed
    }

    /// Stages the given paths (`git add --`). Returns nil on success or the
    /// combined output on failure.
    public static func stage(paths: [String], at repoPath: String) async -> String? {
        guard !paths.isEmpty else { return nil }
        return await runWithError(["add", "--"] + paths, at: repoPath)
    }

    /// Unstages the given paths (`git reset HEAD --`). Returns nil on success.
    public static func unstage(paths: [String], at repoPath: String) async -> String? {
        guard !paths.isEmpty else { return nil }
        return await runWithError(["reset", "HEAD", "--"] + paths, at: repoPath)
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
    private static func runWithError(_ args: [String], at path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = gitEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch { return "\(error)" }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        if process.terminationStatus == 0 { return nil }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") +
                       (String(data: errData, encoding: .utf8) ?? "")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "git \(args.first ?? "") exited \(process.terminationStatus)" : trimmed
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

    /// Returns local branch names ordered by most recent commit first.
    public static func listLocalBranches(at path: String) async -> [String] {
        guard let result = await run(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/"],
            at: path
        ) else {
            return []
        }
        return result
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#endif
