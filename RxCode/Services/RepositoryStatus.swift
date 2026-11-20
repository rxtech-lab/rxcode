import Foundation
import RxCodeCore

nonisolated struct GitChangeFile: Identifiable, Hashable, Sendable {
    var id: String { displayPath }
    let path: String        // absolute path
    let displayPath: String // path relative to repo
    let statusChar: Character
    let originalPath: String?
    let diffMode: PreviewFile.GitDiffMode
    var pathspecs: [String] { [displayPath] + (originalPath.map { [$0] } ?? []) }

    var name: String {
        (displayPath as NSString).lastPathComponent
    }

    var parentDirectory: String {
        (displayPath as NSString).deletingLastPathComponent
    }
}

nonisolated struct GitChangesSnapshot: Equatable, Sendable {
    let unstaged: [GitChangeFile]
    let staged: [GitChangeFile]
}

nonisolated func loadAllChangedFiles(at projectPath: String) async -> GitChangesSnapshot? {
    guard let raw = await GitHelper.run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], at: projectPath) else { return nil }
    return parsePorcelainZ(raw, projectPath: projectPath)
}

/// Parses `git status --porcelain=v1 -z` output into both unstaged and staged
/// file lists. Entries are NUL-terminated; renames have an extra NUL-terminated
/// "old path" record.
nonisolated func parsePorcelainZ(_ raw: String, projectPath: String) -> GitChangesSnapshot {
    var unstaged: [GitChangeFile] = []
    var staged: [GitChangeFile] = []
    let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < tokens.count {
        let entry = tokens[i]
        i += 1
        guard entry.count >= 3 else { continue }
        let chars = Array(entry)
        let indexChar = chars[0]
        let worktreeChar = chars[1]
        let displayPath = String(entry.dropFirst(3))

        let isUntracked = (indexChar == "?" && worktreeChar == "?")
        var originalPath: String?
        if ("RC".contains(indexChar) || "RC".contains(worktreeChar)), i < tokens.count {
            originalPath = tokens[i]
            i += 1
        }

        let absolute = (projectPath as NSString).appendingPathComponent(displayPath)

        // Unstaged includes untracked files and any worktree-side change.
        if isUntracked || (worktreeChar != " " && worktreeChar != "?") {
            let statusChar: Character = isUntracked ? "?" : worktreeChar
            let diffMode: PreviewFile.GitDiffMode = isUntracked ? .untracked : .unstaged
            unstaged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: statusChar,
                originalPath: worktreeChar == "R" ? originalPath : nil,
                diffMode: diffMode
            ))
        }

        // Staged: anything with an index-side change other than '?'.
        if !isUntracked, indexChar != " " {
            staged.append(GitChangeFile(
                path: absolute,
                displayPath: displayPath,
                statusChar: indexChar,
                originalPath: indexChar == "R" ? originalPath : nil,
                diffMode: .staged
            ))
        }
    }
    let sort: ([GitChangeFile]) -> [GitChangeFile] = { files in
        files.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }
    return GitChangesSnapshot(unstaged: sort(unstaged), staged: sort(staged))
}

nonisolated struct GitWorkingTree: Sendable, Equatable {
    let root: String
    let head: String
    let upstream: GitHelper.UpstreamStatus?
    let changes: GitChangesSnapshot

    var isDetached: Bool { upstream == nil }
}

nonisolated enum RepositoryState: Sendable, Equatable {
    case loading, notRepository, unavailable
    case ready(GitWorkingTree)

    @concurrent static func load(at path: String) async -> Self {
        guard let root = await gitPath(["--show-toplevel"], at: path) else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path),
                  !FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
            else { return .unavailable }
            return .notRepository
        }
        async let changes = loadAllChangedFiles(at: root)
        async let tracking = GitHelper.upstreamStatus(at: root)
        let (files, upstream) = await (changes, tracking)
        guard let files else { return .unavailable }
        let head: String
        if let upstream {
            head = upstream.branch
        } else if let commit = await gitPath(["--short", "HEAD"], at: root) {
            head = commit
        } else {
            return .unavailable
        }
        return .ready(GitWorkingTree(root: root, head: head, upstream: upstream, changes: files))
    }

    fileprivate static func gitPath(_ args: [String], at path: String) async -> String? {
        guard let raw = await GitHelper.run(["rev-parse"] + args, at: path), !raw.isEmpty else { return nil }
        return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    }
}

/// Window-scoped so the sidebar and inspector share a snapshot of the same checkout.
@MainActor @Observable
final class RepositoryStatus {
    private(set) var path: String?
    private(set) var state: RepositoryState = .loading
    @ObservationIgnored private var latestRequest = UUID()

    func refresh(at directory: String) async {
        guard path == directory else { return }
        let request = UUID()
        latestRequest = request
        let result = await RepositoryState.load(at: directory)
        guard !Task.isCancelled, request == latestRequest, path == directory else { return }
        if state != result { state = result }
    }

    func observe(_ directory: String?) async {
        guard !Task.isCancelled else { return }
        path = directory
        state = .loading
        latestRequest = UUID()
        guard let directory else { return }
        let watcher = DirectoryWatcher()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        async let root = RepositoryState.gitPath(["--show-toplevel"], at: directory)
        async let metadata = RepositoryState.gitPath(["--path-format=absolute", "--git-common-dir"], at: directory)
        let (rootPath, gitDirectory) = await (root, metadata)
        let worktree = URL(fileURLWithPath: rootPath ?? directory).standardizedFileURL
        await watcher.watch(url: worktree) { continuation.yield(()) }
        // A linked worktree's index and HEAD live outside its working directory.
        if let gitDirectory, !gitDirectory.hasPrefix(worktree.path + "/") {
            await watcher.watch(url: URL(fileURLWithPath: gitDirectory)) { continuation.yield(()) }
        }
        continuation.yield(())
        for await _ in events {
            guard !Task.isCancelled else { break }
            await refresh(at: directory)
        }
        continuation.finish()
        await watcher.unwatchAll()
    }
}
