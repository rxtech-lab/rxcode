import Foundation
import SwiftData

/// A user-defined context-menu entry, configured in the desktop Settings view and
/// persisted on the Mac (the single source of truth). The desktop's `CustomMenuHook`
/// turns each enabled record into a serializable `MenuItem` for the matching
/// surface; mobile fetches the same items over the relay and renders them
/// identically, so no separate sync channel is needed.
///
/// `surface` selects where the item appears (any combination of project / thread /
/// briefing-card menus, stored comma-separated), `projectId == nil` means
/// "all projects", and `actionKind` + the action fields
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

    /// How the item's visibility is decided.
    public enum ConditionType: String, Codable, Sendable, CaseIterable {
        /// No condition — the item is always shown (the default).
        case always
        /// A user-authored Swift script with a
        /// `func checkShowMenu(context: Context) async throws -> Bool` that returns
        /// `true` to show the item. Evaluated on the desktop at menu-build time.
        case swiftScript
    }

    @Attribute(.unique) public var id: String
    /// User-entered display title (plain text — not localized).
    public var title: String
    /// Optional SF Symbol name shown beside the title.
    public var systemImage: String?
    /// `nil` => available in every project; otherwise scoped to this project.
    public var projectId: UUID?
    /// Comma-separated raw `Surface` values (e.g. `"project,thread"`). A single
    /// legacy value (`"project"`) parses identically, so old records keep working.
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

    // Show condition
    /// Raw `ConditionType` value. Defaults to `always` so existing records — and
    /// any new item without a condition — are simply always shown.
    ///
    /// The `= always` default is also load-bearing for SwiftData lightweight
    /// migration: adding a non-optional attribute to an existing entity requires a
    /// default, otherwise the store fails to open and the whole container (which
    /// also holds `ChatThread`) falls back to an empty in-memory store — wiping
    /// all chat history on the next launch.
    public var conditionType: String = ConditionType.always.rawValue
    /// The Swift source for a `swiftScript` condition (the user's
    /// `checkShowMenu(context:)` function). `nil` for `always`.
    public var conditionScript: String?
    /// Whether `conditionScript` last compiled successfully. The editor refuses to
    /// save a `swiftScript` item until this is `true`, so a record on disk with a
    /// script is always known-compiled. Defaulted for lightweight migration (see
    /// `conditionType`).
    public var conditionCompiled: Bool = false

    public var isEnabled: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        systemImage: String? = nil,
        projectId: UUID? = nil,
        surfaces: [Surface],
        actionKind: ActionKind,
        httpMethod: String? = nil,
        urlString: String? = nil,
        headersJSON: String? = nil,
        bodyTemplate: String? = nil,
        messageTemplate: String? = nil,
        targetSessionId: String? = nil,
        conditionType: ConditionType = .always,
        conditionScript: String? = nil,
        conditionCompiled: Bool = false,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.projectId = projectId
        self.surface = CustomMenuItemRecord.encodeSurfaces(surfaces)
        self.actionKind = actionKind.rawValue
        self.httpMethod = httpMethod
        self.urlString = urlString
        self.headersJSON = headersJSON
        self.bodyTemplate = bodyTemplate
        self.messageTemplate = messageTemplate
        self.targetSessionId = targetSessionId
        self.conditionType = conditionType.rawValue
        self.conditionScript = conditionScript
        self.conditionCompiled = conditionCompiled
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// All surfaces this item attaches to, in the stored order. Falls back to
    /// `[.project]` for an empty/unparseable value so the item never disappears.
    public var surfaces: [Surface] {
        let parsed = surface
            .split(separator: ",")
            .compactMap { Surface(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? [.project] : parsed
    }

    /// First surface — kept for callers that only need a single representative value.
    public var surfaceValue: Surface { surfaces.first ?? .project }
    public var actionKindValue: ActionKind { ActionKind(rawValue: actionKind) ?? .createThread }
    /// Decoded condition type. Falls back to `always` for empty/legacy values so an
    /// item without a stored condition is always shown.
    public var conditionTypeValue: ConditionType { ConditionType(rawValue: conditionType) ?? .always }

    /// Encode a surface list to the stored comma-separated representation. Falls
    /// back to `project` when empty so a record always has a home.
    public static func encodeSurfaces(_ surfaces: [Surface]) -> String {
        let list = surfaces.isEmpty ? [Surface.project] : surfaces
        return list.map(\.rawValue).joined(separator: ",")
    }

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
