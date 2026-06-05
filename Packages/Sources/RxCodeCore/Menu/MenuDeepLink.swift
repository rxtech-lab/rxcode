import Foundation

/// Builds and parses the `rxcode://menu/<action>?projectId=…&sessionId=…` deep
/// links carried by `MenuAction.deepLink`.
///
/// Sheet- and setup-style menu items (secrets, docs, release, CI) present
/// platform-local UI rather than running work on the desktop, so they travel as
/// deep links: the desktop maps the link to its existing request methods /
/// sheets, and mobile maps the same link to its own sheets / setup chat. The
/// host `menu` keeps these distinct from the app's other `rxcode://` routes
/// (`secrets/add`, `ci/add`, …) which remain unchanged.
public enum MenuDeepLink {
    public static let scheme = "rxcode"
    public static let host = "menu"

    // Action identifiers (the URL path component).
    public static let secretsSetup = "secrets-setup"
    public static let secretsDownload = "secrets-download"
    public static let docsSetup = "docs-setup"
    public static let docsSearch = "docs-search"
    public static let releaseSetup = "release-setup"
    public static let releaseCreate = "release-create"
    public static let ciSetup = "ci-setup"

    /// Decoded form of a menu deep link.
    public struct Parsed: Equatable, Sendable {
        public let action: String
        public let projectId: UUID?
        public let sessionId: String?

        public init(action: String, projectId: UUID?, sessionId: String?) {
            self.action = action
            self.projectId = projectId
            self.sessionId = sessionId
        }
    }

    /// Build a menu deep link URL for an `action`, addressing a project and/or
    /// thread by id.
    public static func url(action: String, projectId: UUID? = nil, sessionId: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(action)"
        var items: [URLQueryItem] = []
        if let projectId { items.append(URLQueryItem(name: "projectId", value: projectId.uuidString)) }
        if let sessionId { items.append(URLQueryItem(name: "sessionId", value: sessionId)) }
        components.queryItems = items.isEmpty ? nil : items
        // Inputs are always valid here (fixed scheme/host, UUID/string params), so
        // the URL is guaranteed to construct.
        return components.url!
    }

    /// Parse a URL into a menu action, or `nil` if it isn't a `rxcode://menu/…`
    /// deep link.
    public static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == scheme, url.host == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let action = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path
        guard !action.isEmpty else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value
        }
        return Parsed(
            action: action,
            projectId: query["projectId"].flatMap(UUID.init(uuidString:)),
            sessionId: query["sessionId"]
        )
    }
}
