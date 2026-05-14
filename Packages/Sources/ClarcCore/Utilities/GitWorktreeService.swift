import Foundation

// MARK: - GitWorktreeService

public actor GitWorktreeService {
    public static let shared = GitWorktreeService()

    public enum WorktreeError: Error, Sendable, CustomStringConvertible {
        case notARepo
        case branchExists(String)
        case gitFailed(String)
        case fsError(String)

        public var description: String {
            switch self {
            case .notARepo: return "Not a Git repository."
            case .branchExists(let b): return "Branch \"\(b)\" already exists."
            case .gitFailed(let msg): return "Git failed: \(msg)"
            case .fsError(let msg): return "Filesystem error: \(msg)"
            }
        }
    }

    public struct WorktreeInfo: Sendable, Hashable {
        public let path: URL
        public let branch: String
        public let head: String
    }

    private init() {}

    // MARK: - Public API

    public func defaultBaseDir(for baseRepo: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport
            .appendingPathComponent("Clarc", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(baseRepo.lastPathComponent, isDirectory: true)
        return dir
    }

    public func listWorktrees(baseRepo: URL) async throws -> [WorktreeInfo] {
        guard let output = await runGit(["worktree", "list", "--porcelain"], at: baseRepo.path) else {
            throw WorktreeError.notARepo
        }
        return parseWorktreeList(output)
    }

    /// Create a new worktree at `<defaultBaseDir>/<sanitizedBranchName>`.
    /// - If `branch` exists locally, checks it out into the new worktree (no -b).
    /// - Otherwise creates the branch from `fromRef` (default: `HEAD`) and checks it out.
    public func createWorktree(
        baseRepo: URL,
        branch: String,
        fromRef: String = "HEAD"
    ) async throws -> WorktreeInfo {
        let normalizedBranch = Self.sanitizedBranchName(prefix: "", raw: branch)
        let mainGitDir = await mainGitCommonDir(of: baseRepo)
        guard let mainGitDir else { throw WorktreeError.notARepo }
        let mainRepo = mainGitDir.deletingLastPathComponent()

        let baseDir = defaultBaseDir(for: mainRepo)
        try ensureDirectory(baseDir)

        var targetURL = baseDir.appendingPathComponent(safeFilename(from: normalizedBranch))
        targetURL = uniqueDirectoryURL(from: targetURL)

        let branchExistsLocally = await self.branchExists(at: mainRepo.path, branch: normalizedBranch)

        let args: [String]
        if branchExistsLocally {
            args = ["worktree", "add", targetURL.path, normalizedBranch]
        } else {
            args = ["worktree", "add", "-b", normalizedBranch, targetURL.path, fromRef]
        }

        let (status, output) = await runGitCapture(args, at: mainRepo.path)
        guard status == 0 else {
            // Best-effort cleanup of any half-created directory before bubbling up.
            try? FileManager.default.removeItem(at: targetURL)
            throw WorktreeError.gitFailed(output.isEmpty ? "exit \(status)" : output)
        }

        let head = (await runGit(["-C", targetURL.path, "rev-parse", "HEAD"], at: targetURL.path) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorktreeInfo(path: targetURL, branch: normalizedBranch, head: head)
    }

    public func removeWorktree(_ url: URL, force: Bool = false) async throws {
        let mainGitDir = await mainGitCommonDir(of: url)
        let cwd = mainGitDir?.deletingLastPathComponent().path ?? url.deletingLastPathComponent().path

        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(url.path)

        let (status, output) = await runGitCapture(args, at: cwd)
        guard status == 0 else {
            throw WorktreeError.gitFailed(output.isEmpty ? "exit \(status)" : output)
        }
    }

    public func hasUncommittedChanges(at url: URL) async -> Bool {
        guard let output = await runGit(["status", "--porcelain"], at: url.path) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func sanitizedBranchName(prefix: String, raw: String) -> String {
        let combined = prefix.isEmpty ? raw : (raw.hasPrefix(prefix) ? raw : prefix + raw)
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace whitespace and disallowed chars
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/_.-")
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var name = String(scalars)
        // Collapse multiple dashes / slashes
        while name.contains("//") { name = name.replacingOccurrences(of: "//", with: "/") }
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        // Strip leading/trailing slashes and dots
        while name.hasPrefix("/") || name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix("/") || name.hasSuffix(".") { name.removeLast() }
        return name
    }

    // MARK: - Private

    private func runGit(_ args: [String], at path: String) async -> String? {
        await GitHelper.run(args, at: path)
    }

    /// Same as `runGit` but returns (exit_status, combined_output) so callers can see error text.
    private func runGitCapture(_ args: [String], at path: String) async -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "",
            "PAGER": "",
        ]) { _, new in new }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") +
                       (String(data: errData, encoding: .utf8) ?? "")
        return (process.terminationStatus, combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func branchExists(at path: String, branch: String) async -> Bool {
        let (status, _) = await runGitCapture(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            at: path
        )
        return status == 0
    }

    /// Returns the main `.git` common dir for the repo containing `url`.
    /// Works whether `url` is the main worktree or a linked worktree.
    private func mainGitCommonDir(of url: URL) async -> URL? {
        guard let out = await runGit(["rev-parse", "--git-common-dir"], at: url.path) else {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved: URL
        if trimmed.hasPrefix("/") {
            resolved = URL(fileURLWithPath: trimmed)
        } else {
            resolved = URL(fileURLWithPath: url.path).appendingPathComponent(trimmed)
        }
        return resolved.standardizedFileURL
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw WorktreeError.fsError("\(error)")
        }
    }

    private func uniqueDirectoryURL(from url: URL) -> URL {
        var candidate = url
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private func safeFilename(from branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    private func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var path: String?
        var head: String = ""
        var branch: String = ""

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let p = path {
                    result.append(WorktreeInfo(path: URL(fileURLWithPath: p), branch: branch, head: head))
                }
                path = String(line.dropFirst("worktree ".count))
                head = ""
                branch = ""
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                if ref.hasPrefix("refs/heads/") {
                    branch = String(ref.dropFirst("refs/heads/".count))
                } else {
                    branch = ref
                }
            }
        }
        if let p = path {
            result.append(WorktreeInfo(path: URL(fileURLWithPath: p), branch: branch, head: head))
        }
        return result
    }
}
