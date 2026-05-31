import Foundation

/// Request to kick off docs setup for a repo: start a fresh chat seeded with
/// the docs-publishing skill so the agent wires up CI doc uploads.
struct DocsSetupRequest: Identifiable, Hashable {
    let id = UUID()
    var repoFullName: String?
}

/// Parses `rxcode://docs/setup?repo=<owner/repo>` and
/// `rxcode://docs/manage?repo=<owner/repo>` deep links. Returns nil for
/// unrelated URLs.
enum DocsDeepLink {
    static let scheme = "rxcode"

    enum Action: String {
        case setup
        case manage
    }

    struct Parsed {
        let action: Action
        let repoFullName: String?
    }

    static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == scheme else { return nil }
        // Accept both rxcode://docs/setup and rxcode:docs/setup forms.
        let host = url.host
        let firstPath = url.pathComponents.first(where: { $0 != "/" })
        let segment = host ?? firstPath
        guard segment == "docs" else { return nil }

        // The action is the path component after the host (e.g. "setup").
        let actionRaw = (host != nil ? url.pathComponents.first(where: { $0 != "/" }) : url.pathComponents.dropFirst().first(where: { $0 != "/" }))
        let action = Action(rawValue: actionRaw ?? "setup") ?? .setup

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let repo = items.first(where: { $0.name == "repo" })?.value?.removingPercentEncoding
        return Parsed(action: action, repoFullName: repo)
    }

    /// Builds the deep link the docs banner's button opens.
    static func setupURL(repo: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "docs"
        components.path = "/setup"
        components.queryItems = [URLQueryItem(name: "repo", value: repo)]
        return components.url
    }

    static func manageURL(repo: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "docs"
        components.path = "/manage"
        components.queryItems = [URLQueryItem(name: "repo", value: repo)]
        return components.url
    }
}
