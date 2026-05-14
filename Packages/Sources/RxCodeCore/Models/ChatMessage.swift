import Foundation

// MARK: - Message Block

public struct MessageBlock: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var text: String?
    public var toolCall: ToolCall?

    public var isText: Bool { text != nil }
    public var isToolCall: Bool { toolCall != nil }

    public static func text(_ text: String, id: String = UUID().uuidString) -> MessageBlock {
        MessageBlock(id: id, text: text, toolCall: nil)
    }

    public static func toolCall(_ toolCall: ToolCall) -> MessageBlock {
        MessageBlock(id: toolCall.id, text: nil, toolCall: toolCall)
    }
}

// MARK: - Chat Message

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: Role
    public var blocks: [MessageBlock]
    public var isStreaming: Bool
    public var isResponseComplete: Bool
    public let timestamp: Date
    public var attachmentPaths: [AttachmentInfo]
    public var duration: TimeInterval?
    public var isError: Bool
    public var isCompactBoundary: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String = "",
        blocks: [MessageBlock]? = nil,
        isStreaming: Bool = false,
        isResponseComplete: Bool = false,
        timestamp: Date = Date(),
        attachments: [Attachment] = [],
        duration: TimeInterval? = nil,
        isError: Bool = false,
        isCompactBoundary: Bool = false
    ) {
        self.id = id
        self.role = role
        if let blocks {
            self.blocks = blocks
        } else if !content.isEmpty {
            self.blocks = [.text(content)]
        } else {
            self.blocks = []
        }
        self.isStreaming = isStreaming
        self.isResponseComplete = isResponseComplete
        self.timestamp = timestamp
        self.attachmentPaths = attachments.map {
            AttachmentInfo(name: $0.name, path: $0.path, type: $0.type.rawValue)
        }
        self.duration = duration
        self.isError = isError
        self.isCompactBoundary = isCompactBoundary
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, isStreaming, isResponseComplete, timestamp, attachmentPaths, duration, isError, isCompactBoundary
        case content, toolCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        isResponseComplete = try container.decodeIfPresent(Bool.self, forKey: .isResponseComplete) ?? false
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        attachmentPaths = try container.decodeIfPresent([AttachmentInfo].self, forKey: .attachmentPaths) ?? []
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isCompactBoundary = try container.decodeIfPresent(Bool.self, forKey: .isCompactBoundary) ?? false

        if let decodedBlocks = try container.decodeIfPresent([MessageBlock].self, forKey: .blocks) {
            blocks = decodedBlocks
        } else {
            var migrated: [MessageBlock] = []
            if let content = try container.decodeIfPresent(String.self, forKey: .content),
               !content.isEmpty {
                migrated.append(.text(content))
            }
            if let toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) {
                for tc in toolCalls {
                    migrated.append(.toolCall(tc))
                }
            }
            blocks = migrated
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(isResponseComplete, forKey: .isResponseComplete)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(attachmentPaths, forKey: .attachmentPaths)
        try container.encodeIfPresent(duration, forKey: .duration)
        if isError { try container.encode(isError, forKey: .isError) }
        if isCompactBoundary { try container.encode(isCompactBoundary, forKey: .isCompactBoundary) }
    }

    // MARK: - Convenience Accessors

    public var content: String {
        get {
            blocks.compactMap(\.text).joined(separator: "\n\n")
        }
        set {
            blocks.removeAll { $0.isText }
            if !newValue.isEmpty {
                blocks.insert(.text(newValue), at: 0)
            }
        }
    }

    public var toolCalls: [ToolCall] {
        blocks.compactMap(\.toolCall)
    }

    public mutating func appendText(_ text: String) {
        if let lastTextIndex = blocks.lastIndex(where: { $0.isText }) {
            blocks[lastTextIndex].text! += text
        } else {
            blocks.append(.text(text))
        }
    }

    public mutating func appendToolCall(_ toolCall: ToolCall) {
        blocks.append(.toolCall(toolCall))
    }

    public func toolCallIndex(id: String) -> Int? {
        blocks.firstIndex(where: { $0.toolCall?.id == id })
    }

    public mutating func setToolResult(id: String, result: String, isError: Bool) {
        guard let index = toolCallIndex(id: id),
              let toolCall = blocks[index].toolCall else { return }
        if result.isEmpty && !isError && !toolCall.keepsEmptyResult {
            blocks.remove(at: index)
        } else {
            blocks[index].toolCall?.result = result
            blocks[index].toolCall?.isError = isError
        }
    }

    public mutating func finalizeToolCalls() {
        blocks.removeAll { block in
            guard let toolCall = block.toolCall else { return false }
            if toolCall.result == nil { return !toolCall.isKeepAlways }
            if toolCall.keepsEmptyResult { return false }
            return toolCall.result?.isEmpty == true && !toolCall.isError
        }
    }
}

// MARK: - Attachment Info

public struct AttachmentInfo: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let type: String

    public var isImage: Bool { type == "image" }

    public init(name: String, path: String, type: String) {
        self.name = name
        self.path = path
        self.type = type
    }
}

// MARK: - Role

public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

// MARK: - Tool Call

public struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public var input: [String: JSONValue]
    public var result: String?
    public var isError: Bool

    public var hasNonEmptyResult: Bool {
        result.map { !$0.isEmpty } ?? false
    }

    /// Tool names that must stay in the message block even without a result —
    /// either because the result would be empty by design, or because the UI
    /// needs to render them before the user/CLI produces a result.
    public static let keepAlwaysNames: Set<String> = [
        "agent", "edit", "multiedit", "multi_edit", "write", "askuserquestion", "exitplanmode", "exit_plan_mode"
    ]

    public var isKeepAlways: Bool {
        Self.keepAlwaysNames.contains(name.lowercased())
    }

    /// Completed read/execution tools may have an empty result, but the chat UI
    /// still needs the block so it can count them in the collapsed tool summary.
    public var keepsEmptyResult: Bool {
        isKeepAlways || ToolCategory(toolName: name).isTransient
    }

    public init(
        id: String,
        name: String,
        input: [String: JSONValue] = [:],
        result: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
    }
}

// MARK: - File Edit Extraction

public extension ToolCall {
    struct FileChangeDiff: Sendable, Equatable {
        public let path: String
        public let diff: String

        public init(path: String, diff: String) {
            self.path = path
            self.diff = diff
        }

        /// Synthesize a single `(oldString, newString)` hunk from a unified diff
        /// body so Codex `fileChange` calls can flow through the same
        /// `ThreadFileEdit` storage as Claude Edit/MultiEdit/Write.
        public var hunk: PreviewFile.EditHunk {
            var removed: [String] = []
            var added: [String] = []
            for rawLine in diff.components(separatedBy: "\n") {
                if rawLine.hasPrefix("---") || rawLine.hasPrefix("+++") { continue }
                if rawLine.hasPrefix("@@") { continue }
                if rawLine.hasPrefix("-") {
                    removed.append(String(rawLine.dropFirst()))
                } else if rawLine.hasPrefix("+") {
                    added.append(String(rawLine.dropFirst()))
                }
            }
            return PreviewFile.EditHunk(
                oldString: removed.joined(separator: "\n"),
                newString: added.joined(separator: "\n")
            )
        }
    }

    /// Edit/MultiEdit/Write input → list of (old, new) hunks. Returns `[]` for
    /// non-edit tools or malformed input. Write is represented as a single
    /// hunk with `oldString == ""` and `newString == content`, so the existing
    /// diff renderer treats a Write as a pure-additions diff.
    var fileEditHunks: [PreviewFile.EditHunk] {
        switch name.lowercased() {
        case "edit":
            guard let old = input["old_string"]?.stringValue,
                  let new = input["new_string"]?.stringValue else { return [] }
            return [PreviewFile.EditHunk(oldString: old, newString: new)]
        case "multiedit", "multi_edit":
            guard let edits = input["edits"]?.arrayValue else { return [] }
            return edits.compactMap { entry in
                guard let obj = entry.objectValue,
                      let old = obj["old_string"]?.stringValue,
                      let new = obj["new_string"]?.stringValue else { return nil }
                return PreviewFile.EditHunk(oldString: old, newString: new)
            }
        case "write":
            guard let content = input["content"]?.stringValue else { return [] }
            return [PreviewFile.EditHunk(oldString: "", newString: content)]
        default:
            return []
        }
    }

    var fileChangeDiffs: [FileChangeDiff] {
        guard name.lowercased() == "edit",
              let changes = input["changes"]?.arrayValue else { return [] }

        return changes.compactMap { entry in
            guard let obj = entry.objectValue,
                  let path = obj["path"]?.stringValue,
                  let diff = obj["diff"]?.stringValue,
                  !diff.isEmpty else { return nil }
            return FileChangeDiff(path: path, diff: diff)
        }
    }

    var editedFilePath: String? {
        guard ["edit", "multiedit", "multi_edit", "write"].contains(name.lowercased()) else { return nil }
        return input["file_path"]?.stringValue ?? fileChangeDiffs.first?.path
    }
}

// MARK: - File Edit Summary

public struct FileEditSummary: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let name: String
    public let hunks: [PreviewFile.EditHunk]
    /// True if any contributing tool was Write — old content was overwritten,
    /// not surgically edited.
    public let containsWrite: Bool

    public init(path: String, name: String, hunks: [PreviewFile.EditHunk], containsWrite: Bool) {
        self.path = path
        self.name = name
        self.hunks = hunks
        self.containsWrite = containsWrite
    }
}
