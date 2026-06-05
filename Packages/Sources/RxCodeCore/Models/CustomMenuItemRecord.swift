import Foundation
import SwiftData

/// A user-defined context-menu entry, configured in the desktop Settings view and
/// persisted on the Mac (the single source of truth). The desktop's `CustomMenuHook`
/// turns each enabled record into a serializable `MenuItem` for the matching
/// surface; mobile fetches the same items over the relay and renders them
/// identically, so no separate sync channel is needed.
///
/// `surface` selects where the item appears (project / thread / briefing-card menu),
/// `projectId == nil` means "all projects", and `actionKind` + the action fields
/// describe the work the desktop performs when the item is tapped. Template fields
/// (`urlString`, `bodyTemplate`, `messageTemplate`, header values) may contain
/// context placeholders such as `{{projectName}}`, `{{projectPath}}`,
/// `{{gitHubRepo}}`, `{{branch}}`, `{{sessionId}}`, substituted at menu-build time.
@Model
public final class CustomMenuItemRecord {
    /// Which menu surface this item attaches to.
    public enum Surface: String, Codable, Sendable, CaseIterable {
        case project    // generic project menu (sidebar / project list)
        case thread     // a thread's context menu
        case briefing   // a branch-scoped briefing card menu
    }

    /// The action performed when the item is tapped.
    public enum ActionKind: String, Codable, Sendable, CaseIterable {
        case callAPI
        case createThread
        case continueThread
    }

    @Attribute(.unique) public var id: String
    /// User-entered display title (plain text — not localized).
    public var title: String
    /// Optional SF Symbol name shown beside the title.
    public var systemImage: String?
    /// `nil` => available in every project; otherwise scoped to this project.
    public var projectId: UUID?
    /// Raw `Surface` value.
    public var surface: String
    /// Raw `ActionKind` value.
    public var actionKind: String

    // callAPI
    public var httpMethod: String?       // "GET" / "POST" / …
    public var urlString: String?
    /// JSON-encoded `[String: String]` of header name → value (values may template).
    public var headersJSON: String?
    public var bodyTemplate: String?

    // createThread / continueThread
    public var messageTemplate: String?
    /// Target thread id for `continueThread`.
    public var targetSessionId: String?

    public var isEnabled: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        systemImage: String? = nil,
        projectId: UUID? = nil,
        surface: Surface,
        actionKind: ActionKind,
        httpMethod: String? = nil,
        urlString: String? = nil,
        headersJSON: String? = nil,
        bodyTemplate: String? = nil,
        messageTemplate: String? = nil,
        targetSessionId: String? = nil,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.projectId = projectId
        self.surface = surface.rawValue
        self.actionKind = actionKind.rawValue
        self.httpMethod = httpMethod
        self.urlString = urlString
        self.headersJSON = headersJSON
        self.bodyTemplate = bodyTemplate
        self.messageTemplate = messageTemplate
        self.targetSessionId = targetSessionId
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var surfaceValue: Surface { Surface(rawValue: surface) ?? .project }
    public var actionKindValue: ActionKind { ActionKind(rawValue: actionKind) ?? .createThread }

    /// Decoded header map (empty when unset or malformed).
    public var headers: [String: String] {
        guard let headersJSON, let data = headersJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public static func encodeHeaders(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty, let data = try? JSONEncoder().encode(headers) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
