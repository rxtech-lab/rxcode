import Foundation
import SwiftData

// MARK: - Detected Shell File Change

/// Classification of a file delta produced during a shell/script tool execution.
public enum DetectedFileChangeKind: String, Codable, Sendable, Equatable {
    case created
    case modified
    case deleted
}

/// Summary and compact unified diff for a single workspace file modified by a
/// shell/script tool call (`Bash`, `exec_command`, `run_command`, etc.).
///
/// Stored inside `ToolCall.input[ToolCall.detectedFileChangesInputKey]` as pure
/// `JSONValue` entries so live streams, SwiftData persistence, and mobile sync
/// carry per-command file diffs without breaking wire compatibility.
public struct DetectedShellFileChange: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }

    /// Absolute path on disk.
    public let path: String
    public let kind: DetectedFileChangeKind
    public let addedLines: Int
    public let removedLines: Int
    /// Compact unified diff snippet (`@@ -o,c +n,c @@` + context/added/removed lines).
    public let diff: String
    /// True when two mutating shell commands overlapped in the same workspace
    /// without a decisive PID/command-token tie-breaker.
    public let isAmbiguous: Bool

    public init(
        path: String,
        kind: DetectedFileChangeKind,
        addedLines: Int,
        removedLines: Int,
        diff: String,
        isAmbiguous: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.diff = diff
        self.isAmbiguous = isAmbiguous
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var hunk: PreviewFile.EditHunk {
        ToolCall.FileChangeDiff(path: path, diff: diff).hunk
    }

    public func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [
            "path": .string(path),
            "kind": .string(kind.rawValue),
            "addedLines": .number(Double(addedLines)),
            "removedLines": .number(Double(removedLines)),
            "diff": .string(diff),
        ]
        if isAmbiguous {
            dict["isAmbiguous"] = .bool(true)
        }
        return .object(dict)
    }

    public init?(jsonValue: JSONValue) {
        guard let obj = jsonValue.objectValue,
              let path = obj["path"]?.stringValue,
              let kindRaw = obj["kind"]?.stringValue,
              let kind = DetectedFileChangeKind(rawValue: kindRaw) else {
            return nil
        }
        self.path = path
        self.kind = kind
        self.addedLines = Int(obj["addedLines"]?.numberValue ?? 0)
        self.removedLines = Int(obj["removedLines"]?.numberValue ?? 0)
        self.diff = obj["diff"]?.stringValue ?? ""
        self.isAmbiguous = obj["isAmbiguous"]?.boolValue ?? false
    }
}

// MARK: - ToolCall Shell Change Helpers

public extension ToolCall {
    /// Synthetic input key storing `[DetectedShellFileChange]` on shell tool calls.
    static let detectedFileChangesInputKey = "_rxcode_detected_file_changes"

    /// Synthetic input key set by `ACPService` when an ACP tool call has `kind == "execute"`.
    static let acpKindInputKey = "_acp_kind"

    private static let localCodeReplNames: Set<String> = [
        "js_repl", "node_repl", "python_repl",
        "mcp__js_repl", "mcp__node_repl", "mcp__python_repl",
    ]

    /// Tool input dictionary with internal RxCode metadata keys removed for UI display.
    var displayInput: [String: JSONValue] {
        input.filter { key, _ in
            key != Self.detectedFileChangesInputKey && key != Self.acpKindInputKey
        }
    }

    /// True if this tool call executes a shell command or script in the workspace.
    var isShellExecutionTool: Bool {
        if ToolCategory(toolName: name) == .execution {
            return true
        }
        if input[Self.acpKindInputKey]?.stringValue?.lowercased() == "execute" {
            return true
        }
        let lowerName = name.lowercased()
        if Self.localCodeReplNames.contains(lowerName)
            || lowerName.hasPrefix("mcp__node_repl__")
            || lowerName.hasPrefix("mcp__js_repl__") {
            return true
        }
        // Fallback for custom agent tool names carrying a `command` field that
        // aren't structured file-edit or MCP tools.
        if ToolCategory(toolName: name) == .unknown,
           editedFilePath == nil,
           shellCommandString != nil {
            return true
        }
        return false
    }

    /// Best-effort shell command string extracted from tool input across
    /// Claude (`command`), Codex (`command` string, `commandActions`, argv array, or `cmd`), and ACP.
    var shellCommandString: String? {
        for key in ["command", "cmd", "script"] {
            if let str = input[key]?.stringValue, !str.isEmpty {
                return ShellCommandClassifier.unwrapShellCommand(str)
            }
            if let arr = input[key]?.arrayValue {
                let parts = arr.compactMap(\.stringValue)
                if !parts.isEmpty {
                    // Unwrap `["bash", "-lc", "python3 ..."]` to the inner script when present.
                    if parts.count >= 3,
                       parts[1].hasPrefix("-"),
                       parts[1].contains("c") {
                        return ShellCommandClassifier.unwrapShellCommand(
                            parts.dropFirst(2).joined(separator: " ")
                        )
                    }
                    return ShellCommandClassifier.unwrapShellCommand(parts.joined(separator: " "))
                }
            }
        }
        if let actions = input["commandActions"]?.arrayValue {
            let cmds = actions.compactMap { $0.objectValue?["command"]?.stringValue }.filter { !$0.isEmpty }
            if !cmds.isEmpty {
                return ShellCommandClassifier.unwrapShellCommand(cmds.joined(separator: "\n"))
            }
        }
        if let args = input["arguments"]?.objectValue {
            if let str = args["command"]?.stringValue, !str.isEmpty {
                return ShellCommandClassifier.unwrapShellCommand(str)
            }
            if let str = args["cmd"]?.stringValue, !str.isEmpty {
                return ShellCommandClassifier.unwrapShellCommand(str)
            }
        }
        let lowerName = name.lowercased()
        if Self.localCodeReplNames.contains(lowerName)
            || lowerName.hasPrefix("mcp__node_repl__")
            || lowerName.hasPrefix("mcp__js_repl__") {
            let replCode = input["code"]?.stringValue
                ?? input["arguments"]?.objectValue?["code"]?.stringValue
                ?? input["input"]?.stringValue
            if let replCode, !replCode.isEmpty {
                let runner = lowerName.contains("python") ? "python3 -c" : "node -e"
                return "\(runner) \(replCode)"
            }
        }
        return nil
    }

    /// Optional per-command working directory override (e.g. Codex `commandExecution.cwd`).
    var shellWorkingDirectory: String? {
        for key in ["cwd", "workdir", "working_directory"] {
            if let dir = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dir.isEmpty {
                return dir
            }
        }
        if let args = input["arguments"]?.objectValue,
           let dir = args["cwd"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        return nil
    }

    /// Optional explicit script file path attached by the agent runtime (e.g. Codex `scriptPath`).
    var referencedScriptPath: String? {
        guard let path = input["scriptPath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// File changes detected by `WorkspaceChangeTracker` during this shell command.
    var detectedShellFileChanges: [DetectedShellFileChange] {
        guard let raw = input[Self.detectedFileChangesInputKey] else { return [] }
        if let arr = raw.arrayValue {
            return arr.compactMap(DetectedShellFileChange.init(jsonValue:))
        }
        if let jsonString = raw.stringValue,
           let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DetectedShellFileChange].self, from: data) {
            return decoded
        }
        return []
    }

    /// Attaches or clears detected file changes on this `ToolCall`.
    mutating func setDetectedShellFileChanges(_ changes: [DetectedShellFileChange]) {
        if changes.isEmpty {
            input.removeValue(forKey: Self.detectedFileChangesInputKey)
        } else {
            input[Self.detectedFileChangesInputKey] = .array(changes.map { $0.toJSONValue() })
        }
    }
}

// MARK: - Sidecar Persistence for CLI-Backed Sessions

/// Sidecar SwiftData row persisting `[DetectedShellFileChange]` per `(sessionId, toolCallId)`.
///
/// Needed for CLI-backed sessions (`~/.claude/projects/.../*.jsonl`) where reloading
/// a conversation re-parses the CLI's on-disk JSONL and would otherwise lose
/// RxCode-detected shell file changes attached to `ToolCall.input`.
@Model
public final class ToolDetectedChangeRecord {
    public var sessionId: String
    public var toolCallId: String
    public var changesData: Data
    public var updatedAt: Date

    public init(
        sessionId: String,
        toolCallId: String,
        changes: [DetectedShellFileChange],
        updatedAt: Date = .now
    ) {
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.changesData = (try? JSONEncoder().encode(changes)) ?? Data()
        self.updatedAt = updatedAt
    }

    public var changes: [DetectedShellFileChange] {
        get {
            (try? JSONDecoder().decode([DetectedShellFileChange].self, from: changesData)) ?? []
        }
        set {
            changesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = .now
        }
    }
}
