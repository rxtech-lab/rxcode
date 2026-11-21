import Foundation

// MARK: - Models

/// A ref decoration attached to a commit in the history graph.
public struct GitRef: Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable, Comparable {
        case head, localBranch, remoteBranch, tag, other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let kind: Kind
    /// Short display name such as `main`, `origin/main`, or `v1.0`.
    public let name: String
    /// True when HEAD points at this local branch.
    public let isCurrent: Bool

    public init(kind: Kind, name: String, isCurrent: Bool = false) {
        self.kind = kind
        self.name = name
        self.isCurrent = isCurrent
    }
}

/// One commit read from `git log`.
public struct GitCommit: Identifiable, Hashable, Sendable {
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let subject: String
    public let body: String
    public let refs: [GitRef]

    public init(
        id: String,
        parents: [String],
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        subject: String,
        body: String = "",
        refs: [GitRef] = []
    ) {
        self.id = id
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
        self.body = body
        self.refs = refs
    }

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
    public var isHead: Bool { refs.contains { $0.kind == .head || $0.isCurrent } }

    /// Subject and body joined the way `git log --format=%B` would print them.
    public var fullMessage: String {
        body.isEmpty ? subject : subject + "\n\n" + body
    }
}

/// A file changed by a commit, from `git diff-tree --name-status -z`.
public struct GitCommitFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let status: Character
    public let path: String
    public let originalPath: String?

    public init(status: Character, path: String, originalPath: String? = nil) {
        self.status = status
        self.path = path
        self.originalPath = originalPath
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var parentDirectory: String { (path as NSString).deletingLastPathComponent }
}

public struct GitLocalBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let upstream: String?
    public let upstreamRemote: String?
    public let upstreamRef: String?
    public let ahead: Int
    public let behind: Int
    public let isCurrent: Bool
    public let tip: String

    public init(
        name: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        isCurrent: Bool,
        tip: String,
        upstreamRemote: String? = nil,
        upstreamRef: String? = nil
    ) {
        self.name = name
        self.upstream = upstream
        self.upstreamRemote = upstreamRemote
        self.upstreamRef = upstreamRef
        self.ahead = ahead
        self.behind = behind
        self.isCurrent = isCurrent
        self.tip = tip
    }

    public var refName: String { "refs/heads/\(name)" }

    public func pushDestination(on remote: String) -> String {
        if upstreamRemote == remote, let upstreamRef { return upstreamRef }
        return refName
    }
}

public struct GitRemoteBranch: Identifiable, Hashable, Sendable {
    public var id: String { remote + "/" + name }
    public let remote: String
    public let name: String
    public let tip: String

    public init(remote: String, name: String, tip: String) {
        self.remote = remote
        self.name = name
        self.tip = tip
    }

    public var refName: String { remote + "/" + name }
}

public struct GitTag: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let tip: String

    public init(name: String, tip: String) {
        self.name = name
        self.tip = tip
    }
}

public struct GitStash: Identifiable, Hashable, Sendable {
    public var id: String { selector }
    /// Reflog selector such as `stash@{0}`.
    public let selector: String
    public let message: String
    public let tip: String

    public init(selector: String, message: String, tip: String) {
        self.selector = selector
        self.message = message
        self.tip = tip
    }
}

/// A multi-step operation git paused in the repository.
public enum GitPendingOperation: String, Sendable, CaseIterable {
    case rebase, merge, cherryPick, revert

    /// Subcommand used for `--continue`, `--abort`, and `--skip`.
    public var command: String {
        switch self {
        case .rebase: "rebase"
        case .merge: "merge"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    public var supportsSkip: Bool { self != .merge }

    /// Paths relative to the git directory that exist while this operation is paused.
    var markers: [String] {
        switch self {
        case .rebase: ["rebase-merge", "rebase-apply"]
        case .merge: ["MERGE_HEAD"]
        case .cherryPick: ["CHERRY_PICK_HEAD"]
        case .revert: ["REVERT_HEAD"]
        }
    }
}

// MARK: - Parsing

public enum GitHistoryParser {
    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// `git log` format consumed by `parseLog`. Use together with `--decorate=full`.
    public static let logFormat = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%b%x1e"

    public static func parseLog(_ raw: String) -> [GitCommit] {
        raw.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, maxSplits: 7, omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let body = fields.count > 7 ? String(fields[7]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return GitCommit(
                id: id,
                parents: fields[1].split(separator: " ").map(String.init),
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                authorDate: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                subject: String(fields[6]),
                body: body,
                refs: parseDecorations(String(fields[5]))
            )
        }
    }

    /// Parses `%D` output produced with `--decorate=full`, for example
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
    public static func parseDecorations(_ raw: String) -> [GitRef] {
        var refs: [GitRef] = []
        for part in raw.components(separatedBy: ", ") {
            var item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.hasPrefix("HEAD -> ") {
                item.removeFirst("HEAD -> ".count)
                refs.append(ref(for: item, isCurrent: true))
            } else if item == "HEAD" {
                refs.append(GitRef(kind: .head, name: "HEAD"))
            } else if item.hasPrefix("tag: ") {
                item.removeFirst("tag: ".count)
                refs.append(ref(for: item, isCurrent: false))
            } else {
                refs.append(ref(for: item, isCurrent: false))
            }
        }
        return refs
            .filter { !($0.kind == .remoteBranch && $0.name.hasSuffix("/HEAD")) }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.kind < rhs.kind
            }
    }

    private static func ref(for fullName: String, isCurrent: Bool) -> GitRef {
        for (prefix, kind) in [("refs/heads/", GitRef.Kind.localBranch), ("refs/remotes/", .remoteBranch), ("refs/tags/", .tag)]
        where fullName.hasPrefix(prefix) {
            return GitRef(kind: kind, name: String(fullName.dropFirst(prefix.count)), isCurrent: isCurrent)
        }
        return GitRef(kind: .other, name: fullName, isCurrent: isCurrent)
    }

    /// Parses `git diff-tree -r --name-status -z` output.
    public static func parseNameStatus(_ raw: String) -> [GitCommitFile] {
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [GitCommitFile] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard let code = status.first, index < tokens.count else { break }
            if code == "R" || code == "C" {
                guard index + 1 < tokens.count else { break }
                files.append(GitCommitFile(status: code, path: tokens[index + 1], originalPath: tokens[index]))
                index += 2
            } else {
                files.append(GitCommitFile(status: code, path: tokens[index]))
                index += 1
            }
        }
        return files
    }

    /// Parses `git for-each-ref` output using `GitRepositoryLoader.branchFormat`.
    public static func parseLocalBranches(_ raw: String) -> [GitLocalBranch] {
        raw.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[0].isEmpty else { return nil }
            let counts = parseTrack(fields[3])
            return GitLocalBranch(
                name: fields[0],
                upstream: fields[1].isEmpty ? nil : fields[1],
                ahead: counts.ahead,
                behind: counts.behind,
                isCurrent: fields[2] == "*",
                tip: fields[4],
                upstreamRemote: fields.count > 5 && !fields[5].isEmpty ? fields[5] : nil,
                upstreamRef: fields.count > 6 && !fields[6].isEmpty ? fields[6] : nil
            )
        }
    }

    /// Parses `%(upstream:track)` such as `[ahead 2, behind 1]` or `[gone]`.
    public static func parseTrack(_ raw: String) -> (ahead: Int, behind: Int) {
        var ahead = 0
        var behind = 0
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        for part in trimmed.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, let value = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = value }
            if words[0] == "behind" { behind = value }
        }
        return (ahead, behind)
    }
}

// MARK: - Graph Layout

/// Drawing instructions for one row of the commit graph. Columns are lane
/// indexes; `y` positions are relative to the row (top edge, node center, bottom edge).
public struct GitGraphRow: Hashable, Sendable {
    public enum Anchor: Hashable, Sendable { case top, center, bottom }

    public struct Segment: Hashable, Sendable {
        public let fromColumn: Int
        public let from: Anchor
        public let toColumn: Int
        public let to: Anchor
        public let colorIndex: Int

        public init(fromColumn: Int, from: Anchor, toColumn: Int, to: Anchor, colorIndex: Int) {
            self.fromColumn = fromColumn
            self.from = from
            self.toColumn = toColumn
            self.to = to
            self.colorIndex = colorIndex
        }
    }

    public let column: Int
    public let colorIndex: Int
    public let segments: [Segment]
    /// Number of lanes this row spans, used to size the graph column.
    public let width: Int
}

public enum GitGraphLayout {
    /// Assigns each commit a lane and the line segments that connect it to its
    /// children above and parents below. Commits must be in topological order
    /// (children before parents), as `git log --topo-order` prints them.
    public static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []
        var laneColors: [Int] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            var segments: [GitGraphRow.Segment] = []
            let incoming = lanes.indices.filter { lanes[$0] == commit.id }
            let column: Int
            if let first = incoming.first {
                column = first
            } else {
                column = freeLane()
                laneColors[column] = nextColor
                nextColor += 1
            }
            let before = lanes

            // Lanes above that were waiting for this commit converge on its node.
            for lane in incoming {
                segments.append(.init(fromColumn: lane, from: .top, toColumn: column, to: .center, colorIndex: laneColors[lane]))
                if lane != column { lanes[lane] = nil }
            }
            let color = laneColors[column]

            // Continue the commit's lane with its first parent; open lanes for merges.
            lanes[column] = commit.parents.first
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.indices.first(where: { lanes[$0] == parent && $0 != column }) {
                    segments.append(.init(fromColumn: column, from: .center, toColumn: existing, to: .bottom, colorIndex: laneColors[existing]))
                } else {
                    let lane = freeLane()
                    lanes[lane] = parent
                    laneColors[lane] = nextColor
                    nextColor += 1
                    segments.append(.init(fromColumn: column, from: .center, toColumn: lane, to: .bottom, colorIndex: laneColors[lane]))
                }
            }
            if commit.parents.first != nil {
                // Another lane may already wait for the first parent; merge into it below.
                if let parent = commit.parents.first,
                   let shared = lanes.indices.first(where: { lanes[$0] == parent && $0 != column }), shared < column {
                    lanes[column] = nil
                    segments.append(.init(fromColumn: column, from: .center, toColumn: shared, to: .bottom, colorIndex: color))
                } else {
                    segments.append(.init(fromColumn: column, from: .center, toColumn: column, to: .bottom, colorIndex: color))
                }
            }

            // Lanes not involved with this commit pass straight through.
            for lane in before.indices where lane != column && !incoming.contains(lane) && before[lane] != nil {
                segments.append(.init(fromColumn: lane, from: .top, toColumn: lane, to: .bottom, colorIndex: laneColors[lane]))
            }

            let width = max(before.count, lanes.count, column + 1)
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }
            rows.append(GitGraphRow(column: column, colorIndex: color, segments: segments, width: width))
        }
        return rows
    }
}

// MARK: - Interactive Rebase

public struct GitRebaseStep: Identifiable, Hashable, Sendable {
    public enum Action: String, CaseIterable, Hashable, Sendable {
        case pick, reword, squash, fixup, drop
    }

    public var id: String { commit }
    public let commit: String
    public let subject: String
    public var action: Action
    /// New message for `reword`. Ignored by other actions.
    public var message: String

    public init(commit: String, subject: String, action: Action = .pick, message: String = "") {
        self.commit = commit
        self.subject = subject
        self.action = action
        self.message = message
    }
}

public enum GitRebasePlan {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case squashWithoutTarget
        case emptyRewordMessage
    }

    public static func validate(_ steps: [GitRebaseStep]) -> ValidationError? {
        guard steps.contains(where: { $0.action != .drop }) else { return .empty }
        if let first = steps.first(where: { $0.action != .drop }), first.action == .squash || first.action == .fixup {
            return .squashWithoutTarget
        }
        if steps.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .emptyRewordMessage
        }
        return nil
    }

    /// Builds a todo list for `git rebase -i`, oldest commit first. Rewords run
    /// as `pick` followed by an `exec` that amends the message from a file, so
    /// git never needs to open an interactive editor.
    public static func todo(for steps: [GitRebaseStep], messageFile: (GitRebaseStep) -> String) -> String {
        var lines: [String] = []
        for step in steps {
            switch step.action {
            case .reword:
                lines.append("pick \(step.commit) \(step.subject)")
                lines.append("exec git commit --amend --allow-empty --only --cleanup=strip -F \(shellQuoted(messageFile(step)))")
            default:
                lines.append("\(step.action.rawValue) \(step.commit) \(step.subject)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
