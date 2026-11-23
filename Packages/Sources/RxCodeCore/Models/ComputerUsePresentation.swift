import CoreGraphics
import Foundation

/// A window observed by a computer-use tool in the current turn.
public struct ComputerUseMonitorWindow: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        /// A native app driven by computer use, keyed by its bundle identifier so
        /// title changes (new tab, new document) keep updating the same preview.
        case native(appID: String)
        case browser(browserID: String, tabID: String)
    }

    public let id: ID
    public let title: String
    public let appName: String?
    /// The accessibility window title reported by the tool, used to pick the
    /// matching window for live capture. `nil` when the tool did not report one.
    public let windowTitle: String?
    public let preview: CGImage?
    /// When a tool last reported this window; the preview follows the most recent one.
    public let observedAt: Date

    public init(
        id: ID,
        title: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        preview: CGImage? = nil,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.appName = appName
        self.windowTitle = windowTitle
        self.preview = preview
        self.observedAt = observedAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.appName == rhs.appName
            && lhs.windowTitle == rhs.windowTitle && lhs.observedAt == rhs.observedAt
            && lhs.preview === rhs.preview
    }

    /// Combines a newer observation of the same window with what is already
    /// known, keeping details the newer (often diff-only) observation omits.
    public func updated(with newer: Self) -> Self {
        Self(
            id: id,
            title: newer.windowTitle == nil && windowTitle != nil ? title : newer.title,
            appName: newer.appName ?? appName,
            windowTitle: newer.windowTitle ?? windowTitle,
            preview: newer.preview ?? preview,
            observedAt: max(observedAt, newer.observedAt)
        )
    }
}

/// Presentation only: recognizing a tool never grants it permission.
public enum ComputerUsePresentation {
    public static func recognizes(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["computer", "computer_use", "computeruse", "computer_call", "mcp__cua", "mcp__cua_repl", "mcp__computer_use"].contains(name)
            || name.hasPrefix("mcp__cua__")
            || name.hasPrefix("mcp__cua_repl__")
            || name.hasPrefix("mcp__computer_use__")
            || name.hasPrefix("cua_repl.")
    }

    public static func summary(name: String, input: [String: JSONValue]) -> String? {
        guard recognizes(name) else { return nil }
        let action = input["action"]?.objectValue
        let description = input["title"]?.stringValue
            ?? input["action"]?.stringValue
            ?? action?["type"]?.stringValue
        guard let description, !description.isEmpty else { return "Computer use" }
        return "Computer use — \(description.replacingOccurrences(of: "_", with: " "))"
    }
}
