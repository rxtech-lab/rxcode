import Foundation

public struct ChatSession: Identifiable, Codable, Sendable {
    public static let defaultTitle = "New Session"

    public let id: String
    public let projectId: UUID
    public var title: String
    public var messages: [ChatMessage]
    public let createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var origin: SessionOrigin
    public var worktreePath: String?
    public var worktreeBranch: String?
    public var isArchived: Bool
    public var archivedAt: Date?

    public init(
        id: String,
        projectId: UUID,
        title: String = ChatSession.defaultTitle,
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        origin: SessionOrigin = .cliBacked,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        isArchived: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.origin = origin
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.isArchived = isArchived
        self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, messages, createdAt, updatedAt, isPinned, model, effort, permissionMode, origin, worktreePath, worktreeBranch, isArchived, archivedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .legacyClarc
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    public struct Summary: Identifiable, Codable, Sendable, Equatable {
        public let id: String
        public let projectId: UUID
        public var title: String
        public let createdAt: Date
        public var updatedAt: Date
        public var isPinned: Bool
        public var model: String?
        public var effort: String?
        public var permissionMode: PermissionMode?
        public var origin: SessionOrigin
        public var worktreePath: String?
        public var worktreeBranch: String?
        public var isArchived: Bool
        public var archivedAt: Date?

        public init(
            id: String,
            projectId: UUID,
            title: String,
            createdAt: Date,
            updatedAt: Date,
            isPinned: Bool,
            model: String? = nil,
            effort: String? = nil,
            permissionMode: PermissionMode? = nil,
            origin: SessionOrigin = .cliBacked,
            worktreePath: String? = nil,
            worktreeBranch: String? = nil,
            isArchived: Bool = false,
            archivedAt: Date? = nil
        ) {
            self.id = id
            self.projectId = projectId
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.isPinned = isPinned
            self.model = model
            self.effort = effort
            self.permissionMode = permissionMode
            self.origin = origin
            self.worktreePath = worktreePath
            self.worktreeBranch = worktreeBranch
            self.isArchived = isArchived
            self.archivedAt = archivedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, projectId, title, createdAt, updatedAt, isPinned, model, effort, permissionMode, origin, worktreePath, worktreeBranch, isArchived, archivedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            projectId = try container.decode(UUID.self, forKey: .projectId)
            title = try container.decode(String.self, forKey: .title)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
            permissionMode = try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
            origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .legacyClarc
            worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
            worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
            isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
            archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        }
    }

    public var summary: Summary {
        Summary(
            id: id,
            projectId: projectId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            origin: origin,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            isArchived: isArchived,
            archivedAt: archivedAt
        )
    }

    /// Strip attachment markers from user message content so titles and prompts
    /// don't surface internal tokens. Removes:
    ///   - `[Attached image: ...]`, `[Attached file: ...]`, `[Pasted text: ...]`, `[Link: ...]`
    ///   - `[Image1]`, `[Image2]`, ... display tokens
    /// Collapses runs of whitespace and trims edges.
    public static func stripAttachmentMarkers(from content: String) -> String {
        content
            .replacingOccurrences(
                of: #"\[(Attached [A-Za-z]+|Pasted text|Link):[^\]]*\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[Image\d+\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a sidebar-friendly title from a user message. Strips attachment markers
    /// via `stripAttachmentMarkers` so the sidebar doesn't briefly show internal
    /// markers before the LLM-generated title arrives. Returns `defaultTitle` when
    /// the message is empty after stripping.
    public static func placeholderTitle(from content: String) -> String {
        let stripped = stripAttachmentMarkers(from: content)
        guard !stripped.isEmpty else { return defaultTitle }
        return stripped.count > 50 ? String(stripped.prefix(50)) + "..." : stripped
    }

    /// Result of parsing user-message content that may contain `[Attached image: /path]` markers.
    /// Used by the chat bubble to render the actual image and display the cleaned text.
    public struct DisplayedContent: Equatable, Sendable {
        public let text: String
        public let imagePaths: [String]
    }

    /// Extract `[Attached image: /path]` markers from user content, returning the cleaned
    /// text and the list of image paths. `[ImageN]` chip tokens are left in place — they're
    /// rendered as styled chips in the bubble, not stripped. Other `[Attached X: ...]` /
    /// `[Pasted text: ...]` / `[Link: ...]` markers are stripped from the text since they
    /// have no inline representation. Whitespace runs are collapsed and edges trimmed.
    public static func extractDisplayedContent(from content: String) -> DisplayedContent {
        let imageRegex = try! NSRegularExpression(pattern: #"\[Attached image:\s*([^\]]+)\]"#)
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var paths: [String] = []
        imageRegex.enumerateMatches(in: content, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let path = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { paths.append(path) }
        }
        let cleaned = content
            .replacingOccurrences(
                of: #"\[(Attached [A-Za-z]+|Pasted text|Link):[^\]]*\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DisplayedContent(text: cleaned, imagePaths: paths)
    }
}

extension ChatSession.Summary {
    public func makeSession() -> ChatSession {
        ChatSession(id: id, projectId: projectId, title: title,
                    messages: [], createdAt: createdAt,
                    updatedAt: updatedAt, isPinned: isPinned,
                    model: model, effort: effort, permissionMode: permissionMode,
                    origin: origin,
                    worktreePath: worktreePath, worktreeBranch: worktreeBranch,
                    isArchived: isArchived, archivedAt: archivedAt)
    }
}
