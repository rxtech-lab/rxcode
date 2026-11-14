import Foundation

// MARK: - Shell Command Disposition

/// Expected filesystem mutation profile of a shell command.
public enum ShellCommandDisposition: String, Sendable, Equatable {
    /// Inspection-only command (`ls`, `rg`, `cat`, `git status`, `git diff`, etc.).
    case readOnly
    /// Build or test runner (`swift test`, `xcodebuild`, `pytest`, `npm test`, etc.).
    case buildOrTest
    /// Script, file tool, redirect, or unrecognized command capable of modifying source files.
    case mutatingOrUnknown
}

// MARK: - Active Shell Span

/// Metadata for an in-flight or recently finished shell tool execution used by
/// `WorkspaceChangeAttribution` to resolve per-thread file ownership without locks.
public struct ActiveShellSpan: Sendable, Equatable {
    public let spanId: UUID
    public var sessionKey: String
    public let streamId: UUID
    public let toolUseId: String
    public let command: String
    public let cwd: String
    public let disposition: ShellCommandDisposition
    public var rootPid: Int32?
    public let startedAt: Date
    public var endedAt: Date?
    /// Normalized path/filename/stem tokens referenced in `command` or any
    /// invoked local/temporary script file.
    public var candidateTokens: Set<String>

    public init(
        spanId: UUID = UUID(),
        sessionKey: String,
        streamId: UUID,
        toolUseId: String,
        command: String,
        cwd: String,
        disposition: ShellCommandDisposition,
        rootPid: Int32? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        candidateTokens: Set<String> = []
    ) {
        self.spanId = spanId
        self.sessionKey = sessionKey
        self.streamId = streamId
        self.toolUseId = toolUseId
        self.command = command
        self.cwd = cwd
        self.disposition = disposition
        self.rootPid = rootPid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.candidateTokens = candidateTokens
    }
}

// MARK: - Shell Command Classifier & Token Extractor

public enum ShellCommandClassifier {
    private static let shellWrapperPrograms: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh"]
    private static let shellBenignShortFlags: Set<Character> = ["l", "i", "s", "e", "u", "x", "f", "p", "v", "B", "P"]

    private static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "whoami", "id", "uname", "hostname", "date", "uptime",
        "cat", "head", "tail", "less", "more", "wc", "nl", "stat", "file",
        "du", "df", "which", "whereis", "type", "command", "env", "printenv",
        "ps", "pgrep", "lsof", "top", "vm_stat", "sysctl", "grep", "egrep", "fgrep", "rg", "ag", "ack",
        "diff", "cmp", "comm", "md5", "shasum", "sha256sum", "cksum",
        "jq", "dirname", "basename", "realpath", "readlink", "true", "false", "sleep", "test", "[",
    ]

    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree",
        "cat-file", "check-ignore", "blame", "shortlog", "describe", "remote",
        "config", "reflog", "for-each-ref", "name-rev", "rev-list",
    ]

    private static let mutatingPrograms: Set<String> = [
        "rm", "rmdir", "unlink", "mv", "cp", "install", "touch", "mkdir", "truncate", "dd", "patch", "tee",
        "python", "python3", "pypy3", "node", "bun", "deno", "tsx", "ts-node",
        "ruby", "perl", "php", "lua", "tclsh", "osascript", "sh", "bash", "zsh", "fish", "dash", "ksh",
        "swiftformat", "clang-format", "black", "isort", "autopep8", "yapf", "gofmt", "rustfmt", "stylua",
    ]

    private static let scriptExtensions: Set<String> = [
        "py", "js", "mjs", "cjs", "ts", "tsx", "rb", "pl", "sh", "bash", "zsh", "patch", "diff", "awk", "sed",
    ]

    /// Unwraps outer login/subshell wrappers such as `/bin/zsh -lc "..."` or
    /// `bash -c '...'` (used heavily by Codex `commandExecution` items) to the
    /// underlying script/command payload when safe to do so.
    public static func unwrapShellCommand(_ rawCommand: String) -> String {
        var current = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            guard !current.isEmpty,
                  !hasFileOutputRedirection(current),
                  splitShellSegments(current).count == 1,
                  let inner = unwrapSingleShellSegment(current) else { break }
            let trimmedInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInner.isEmpty, trimmedInner != current else { break }
            current = trimmedInner
        }
        return current
    }

    /// Classifies a shell command string without executing or blocking it.
    public static func classify(_ rawCommand: String) -> ShellCommandDisposition {
        let trimmed = unwrapShellCommand(rawCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .readOnly }
        if hasFileOutputRedirection(trimmed) { return .mutatingOrUnknown }

        let segments = splitShellSegments(trimmed)
        guard !segments.isEmpty else { return .readOnly }

        var sawBuildOrTest = false
        for segment in segments {
            switch classifySegment(segment, depth: 0) {
            case .mutatingOrUnknown: return .mutatingOrUnknown
            case .buildOrTest: sawBuildOrTest = true
            case .readOnly: continue
            }
        }
        return sawBuildOrTest ? .buildOrTest : .readOnly
    }

    /// Extracts lowercased candidate path suffixes, filenames, and stems from
    /// a shell command and optional referenced script bodies.
    public static func extractCandidatePathTokens(
        from command: String,
        extraScriptContents: [String] = []
    ) -> Set<String> {
        var tokens = Set<String>()
        let unwrapped = unwrapShellCommand(command)
        var sources = unwrapped == command ? [unwrapped] : [unwrapped, command]
        sources.append(contentsOf: extraScriptContents)
        for source in sources {
            collectTokens(from: source, into: &tokens)
        }
        return tokens
    }

    /// Resolves local or temporary script/patch files referenced in `command`
    /// so `WorkspaceChangeTracker` can inspect their contents for target paths.
    public static func extractReferencedScriptPaths(from command: String, cwd: String) -> [String] {
        let unwrapped = unwrapShellCommand(command)
        let segments = splitShellSegments(unwrapped)
        let rawTokens = (segments.isEmpty ? [unwrapped] : segments).flatMap { segment in
            rawWordTokens(unwrapSingleShellSegment(segment) ?? segment)
        }
        var resolved: [String] = []
        var seen = Set<String>()

        for raw in rawTokens {
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;()[]{}<>|&"))
            guard !cleaned.isEmpty, !cleaned.hasPrefix("-"), !cleaned.contains("://") else { continue }
            let ext = (cleaned as NSString).pathExtension.lowercased()
            guard scriptExtensions.contains(ext) else { continue }

            let fullPath: String
            if cleaned.hasPrefix("/") {
                fullPath = (cleaned as NSString).standardizingPath
            } else if cleaned.hasPrefix("~/") {
                fullPath = (cleaned as NSString).expandingTildeInPath
            } else {
                fullPath = ((cwd as NSString).appendingPathComponent(cleaned) as NSString).standardizingPath
            }
            if seen.insert(fullPath).inserted { resolved.append(fullPath) }
        }
        return resolved
    }

    // MARK: - Segment Analysis

    private static func stripLeadingWrappers(_ words: [String], includeTimeout: Bool) -> [String] {
        var rest = words
        let prefixes: Set<String> = includeTimeout
            ? ["env", "time", "nohup", "nice", "timeout"]
            : ["env", "time", "nohup", "nice"]
        while let first = rest.first {
            let stripped = first.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if stripped.isEmpty {
                rest.removeFirst()
                continue
            }
            rest[0] = stripped
            if isEnvAssignment(stripped) || prefixes.contains(stripped) {
                rest.removeFirst()
                continue
            }
            break
        }
        return rest
    }

    private static func unwrapSingleShellSegment(_ rawSegment: String) -> String? {
        let words = stripLeadingWrappers(rawWordTokens(rawSegment), includeTimeout: false)
        guard let head = words.first else { return nil }
        let prog = (head as NSString).lastPathComponent.lowercased()
        guard shellWrapperPrograms.contains(prog) else { return nil }

        var idx = 1
        while idx < words.count {
            let flag = words[idx]
            if flag == "--login" || flag == "--norc" || flag == "--noprofile" {
                idx += 1
                continue
            }
            guard flag.hasPrefix("-"), !flag.hasPrefix("--"), flag.count >= 2 else { break }
            let flagChars = Array(flag.dropFirst())
            if flagChars.contains("c") {
                let remaining = flagChars.filter { $0 != "c" }
                guard remaining.allSatisfy({ shellBenignShortFlags.contains($0) }), idx + 1 < words.count else {
                    return nil
                }
                return words[idx + 1]
            }
            guard flagChars.allSatisfy({ shellBenignShortFlags.contains($0) }) else { return nil }
            idx += 1
        }
        return nil
    }

    private static func classifySegment(_ rawSegment: String, depth: Int) -> ShellCommandDisposition {
        if depth < 4, let inner = unwrapSingleShellSegment(rawSegment) {
            let trimmedInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedInner.isEmpty { return .readOnly }
            if hasFileOutputRedirection(trimmedInner) { return .mutatingOrUnknown }
            var sawBuild = false
            for sub in splitShellSegments(trimmedInner) {
                switch classifySegment(sub, depth: depth + 1) {
                case .mutatingOrUnknown: return .mutatingOrUnknown
                case .buildOrTest: sawBuild = true
                case .readOnly: continue
                }
            }
            return sawBuild ? .buildOrTest : .readOnly
        }

        let words = stripLeadingWrappers(rawWordTokens(rawSegment), includeTimeout: true)
        guard let head = words.first else { return .readOnly }
        let prog = (head as NSString).lastPathComponent.lowercased()
        let args = Array(words.dropFirst())

        if ["cd", "export", "unset", "alias", "set", "echo", "printf"].contains(prog) {
            return .readOnly
        }
        if prog == "sed" {
            return args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "--in-place" })
                ? .mutatingOrUnknown : .readOnly
        }
        if prog == "awk" || prog == "gawk" {
            return args.contains(where: { $0 == "-i" || $0 == "inplace" }) ? .mutatingOrUnknown : .readOnly
        }
        if prog == "yq" {
            return args.contains(where: { $0 == "-i" || $0 == "--inplace" }) ? .mutatingOrUnknown : .readOnly
        }
        if prog == "find" {
            let mutatingFlags: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls"]
            return args.contains(where: { mutatingFlags.contains($0) }) ? .mutatingOrUnknown : .readOnly
        }
        if prog == "fd" {
            return args.contains(where: { ["-x", "--exec", "-X", "--exec-batch"].contains($0) })
                ? .mutatingOrUnknown : .readOnly
        }
        if prog == "sort" {
            return args.contains(where: { $0 == "-o" || $0.hasPrefix("-o") || $0.hasPrefix("--output") })
                ? .mutatingOrUnknown : .readOnly
        }
        if prog == "git" { return classifyGit(args: args) }
        if let buildDisp = classifyBuildOrTest(prog: prog, args: args) { return buildDisp }
        if mutatingPrograms.contains(prog) { return .mutatingOrUnknown }
        if readOnlyPrograms.contains(prog) { return .readOnly }

        // Direct script invocation (`./fix.py`, `/tmp/patch.sh`).
        let ext = (prog as NSString).pathExtension.lowercased()
        if scriptExtensions.contains(ext) || head.hasPrefix("./") { return .mutatingOrUnknown }
        return .mutatingOrUnknown
    }

    private static func classifyGit(args: [String]) -> ShellCommandDisposition {
        // Skip global git flags like `-C <dir>`, `--no-pager`, `-c k=v`.
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "-C" || tok == "-c" || tok == "--git-dir" || tok == "--work-tree" {
                idx += 2
            } else if tok.hasPrefix("-") {
                idx += 1
            } else {
                break
            }
        }
        guard idx < args.count else { return .readOnly }
        let sub = args[idx].lowercased()
        if sub == "branch" {
            let rest = args.dropFirst(idx + 1)
            let safe: Set<String> = ["-a", "-r", "-l", "-v", "-vv", "--list", "--show-current", "--contains"]
            return (rest.isEmpty || rest.allSatisfy { safe.contains($0) }) ? .readOnly : .mutatingOrUnknown
        }
        if sub == "tag" {
            let rest = args.dropFirst(idx + 1)
            return (rest.isEmpty || rest.first == "-l" || rest.first == "--list") ? .readOnly : .mutatingOrUnknown
        }
        return readOnlyGitSubcommands.contains(sub) ? .readOnly : .mutatingOrUnknown
    }

    private static func classifyBuildOrTest(prog: String, args: [String]) -> ShellCommandDisposition? {
        switch prog {
        case "xcodebuild", "pytest", "jest", "vitest", "mocha":
            return .buildOrTest
        case "swiftlint":
            return args.contains(where: { $0 == "--fix" || $0 == "--autocorrect" }) ? .mutatingOrUnknown : .buildOrTest
        case "swift":
            guard let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() else { return .mutatingOrUnknown }
            if sub == "build" || sub == "test" { return .buildOrTest }
            if sub == "package", args.contains(where: { ["resolve", "show-dependencies", "describe", "dump-package"].contains($0) }) {
                return .buildOrTest
            }
            return .mutatingOrUnknown
        case "cargo":
            guard let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() else { return .buildOrTest }
            return ["build", "check", "test", "clippy", "bench", "metadata"].contains(sub) ? .buildOrTest : .mutatingOrUnknown
        case "go":
            guard let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() else { return .buildOrTest }
            return ["build", "test", "vet", "list", "env", "version"].contains(sub) ? .buildOrTest : .mutatingOrUnknown
        case "npm", "pnpm", "yarn":
            guard let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() else { return nil }
            return ["test", "lint", "typecheck", "check"].contains(sub) ? .buildOrTest : .mutatingOrUnknown
        case "tsc":
            return args.contains("--noEmit") ? .buildOrTest : .mutatingOrUnknown
        default:
            return nil
        }
    }

    /// Detects shell output redirection (`>`, `>>`, `&>`) excluding safe
    /// descriptor duplications (`2>&1`, `1>&2`) and `/dev/null` sinks, while
    /// ignoring `>` inside single/double quotes unless unwrapped via `unwrapShellCommand`.
    private static func hasFileOutputRedirection(_ command: String) -> Bool {
        let chars = Array(command)
        var i = 0
        var inSingle = false
        var inDouble = false

        while i < chars.count {
            let c = chars[i]
            if c == "\\", !inSingle {
                i += 2
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                i += 1
                continue
            }
            if c == "\"", !inSingle {
                inDouble.toggle()
                i += 1
                continue
            }
            if !inSingle, !inDouble, c == ">" {
                var nextIdx = i + 1
                if nextIdx < chars.count, chars[nextIdx] == ">" || chars[nextIdx] == "|" { nextIdx += 1 }
                // Ignore descriptor dup `>&1`, `>&2`, `>&-`
                if nextIdx < chars.count, chars[nextIdx] == "&" {
                    let afterAmp = nextIdx + 1
                    if afterAmp < chars.count, chars[afterAmp].isNumber || chars[afterAmp] == "-" {
                        i = afterAmp + 1
                        continue
                    }
                    nextIdx += 1
                }
                while nextIdx < chars.count, chars[nextIdx] == " " || chars[nextIdx] == "\t" { nextIdx += 1 }
                if String(chars[nextIdx...]).hasPrefix("/dev/null") {
                    i = nextIdx + "/dev/null".count
                    continue
                }
                return true
            }
            i += 1
        }
        return false
    }

    private static func splitShellSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let chars = Array(command)
        var i = 0
        var inSingle = false
        var inDouble = false

        while i < chars.count {
            let c = chars[i]
            if c == "\\", !inSingle {
                current.append(c)
                if i + 1 < chars.count { current.append(chars[i + 1]) }
                i += 2
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                current.append(c)
                i += 1
                continue
            }
            if c == "\"", !inSingle {
                inDouble.toggle()
                current.append(c)
                i += 1
                continue
            }
            if !inSingle, !inDouble {
                if c == ";" || c == "\n" {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { segments.append(trimmed) }
                    current = ""
                    i += 1
                    continue
                }
                if c == "|" || c == "&" {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { segments.append(trimmed) }
                    current = ""
                    i += (i + 1 < chars.count && chars[i + 1] == c) ? 2 : 1
                    continue
                }
            }
            current.append(c)
            i += 1
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(trimmed) }
        return segments
    }

    private static func rawWordTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\\", !inSingle {
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if inDouble {
                        // In POSIX double quotes, `\` only escapes `$`, `` ` ``, `"`, `\`, or newline.
                        if next == "\n" {
                            i += 2
                            continue
                        }
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                        } else {
                            current.append("\\")
                            current.append(next)
                        }
                    } else if next != "\n" {
                        current.append(next)
                    }
                }
                i += 2
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                i += 1
                continue
            }
            if c == "\"", !inSingle {
                inDouble.toggle()
                i += 1
                continue
            }
            if !inSingle, !inDouble, c.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func isEnvAssignment(_ word: String) -> Bool {
        guard let eqIdx = word.firstIndex(of: "="), eqIdx != word.startIndex else { return false }
        let name = word[..<eqIdx]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func collectTokens(from text: String, into tokens: inout Set<String>) {
        // Split on delimiters common in shell commands and Python/JS/Ruby string literals.
        let separators = CharacterSet(charactersIn: " \t\r\n\"'`()[]{};,:=<>|&!?*$")
        for rawPiece in text.components(separatedBy: separators) {
            var piece = rawPiece.trimmingCharacters(in: CharacterSet(charactersIn: ".'\""))
            if piece.hasPrefix("./") { piece = String(piece.dropFirst(2)) }
            guard piece.count >= 2, piece.count <= 260, !piece.contains("://") else { continue }

            let lower = piece.lowercased()
            if lower.contains("/") || lower.contains(".") {
                tokens.insert(lower)
                let slashParts = lower.split(separator: "/")
                if slashParts.count >= 2 {
                    tokens.insert(slashParts.suffix(2).joined(separator: "/"))
                }
                let lastComponent = (lower as NSString).lastPathComponent
                if !lastComponent.isEmpty {
                    tokens.insert(lastComponent)
                    let stem = (lastComponent as NSString).deletingPathExtension
                    if stem.count >= 4 { tokens.insert(stem) }
                }
            }
        }
    }
}

// MARK: - Multi-Signal Attribution Resolver

public struct AttributionResult: Sendable, Equatable {
    public let winningSpan: ActiveShellSpan
    public let isAmbiguous: Bool

    public init(winningSpan: ActiveShellSpan, isAmbiguous: Bool) {
        self.winningSpan = winningSpan
        self.isAmbiguous = isAmbiguous
    }
}

public enum WorkspaceChangeAttribution {
    /// Deterministically attributes a changed file to one of the active/completing
    /// shell spans without blocking execution.
    ///
    /// Returns `nil` when all candidate spans are strictly read-only (`rg`, `ls`,
    /// `git status`) without kernel FD write evidence — preventing an external
    /// editor save by the user from being misattributed to a read-only tool call.
    public static func resolve(
        filePath: String,
        rootPath: String,
        candidates: [ActiveShellSpan],
        writerStreamIds: Set<UUID> = [],
        observedBySpanIds: Set<UUID> = []
    ) -> AttributionResult? {
        guard !candidates.isEmpty else { return nil }

        // Filter out readOnly spans unless kernel FD probing explicitly caught
        // that stream opening `filePath` for writing.
        let nonReadOnly = candidates.filter {
            $0.disposition != .readOnly || writerStreamIds.contains($0.streamId)
        }
        guard !nonReadOnly.isEmpty else { return nil }

        // Fast path: only one non-readOnly span is active across all threads.
        if nonReadOnly.count == 1, let single = nonReadOnly.first {
            return AttributionResult(winningSpan: single, isAmbiguous: false)
        }

        // Prefer mutating spans over build/test spans unless a build/test span has
        // direct FD write proof.
        let mutatingPool = nonReadOnly.filter {
            $0.disposition == .mutatingOrUnknown || writerStreamIds.contains($0.streamId)
        }
        let pool = mutatingPool.isEmpty ? nonReadOnly : mutatingPool

        if pool.count == 1, let only = pool.first {
            return AttributionResult(winningSpan: only, isAmbiguous: false)
        }

        let normalizedFile = (filePath as NSString).standardizingPath
        let normalizedRoot = (rootPath as NSString).standardizingPath
        let relPath = normalizedFile.hasPrefix(normalizedRoot + "/")
            ? String(normalizedFile.dropFirst(normalizedRoot.count + 1)).lowercased()
            : normalizedFile.lowercased()
        let fileName = (relPath as NSString).lastPathComponent
        let fileStem = (fileName as NSString).deletingPathExtension
        let comps = relPath.split(separator: "/")
        let parentSuffix = comps.count >= 2 ? comps.suffix(2).joined(separator: "/") : nil

        struct Scored {
            let span: ActiveShellSpan
            let score: Int
            let duration: TimeInterval
        }

        let now = Date()
        let scored: [Scored] = pool.map { span in
            var score = writerStreamIds.contains(span.streamId) ? 1_000 : 0
            if span.candidateTokens.contains(relPath) || span.candidateTokens.contains(normalizedFile.lowercased()) {
                score += 240
            } else if let parentSuffix, span.candidateTokens.contains(parentSuffix) {
                score += 180
            } else if !fileName.isEmpty, span.candidateTokens.contains(fileName) {
                score += 130
            } else if fileStem.count >= 4, span.candidateTokens.contains(fileStem) {
                score += 45
            }

            let normCwd = (span.cwd as NSString).standardizingPath
            if normCwd != normalizedRoot, normalizedFile.hasPrefix(normCwd + "/") { score += 50 }
            if observedBySpanIds.contains(span.spanId) { score += 25 }

            let duration = max(0, (span.endedAt ?? now).timeIntervalSince(span.startedAt))
            return Scored(span: span, score: score, duration: duration)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if abs(lhs.duration - rhs.duration) > 0.001 { return lhs.duration < rhs.duration }
            if lhs.span.startedAt != rhs.span.startedAt { return lhs.span.startedAt > rhs.span.startedAt }
            return lhs.span.spanId.uuidString < rhs.span.spanId.uuidString
        }

        guard let top = sorted.first else { return nil }
        let tiedOtherSession = sorted.dropFirst().contains {
            $0.score == top.score && $0.span.sessionKey != top.span.sessionKey
        }
        return AttributionResult(winningSpan: top.span, isAmbiguous: tiedOtherSession)
    }
}
