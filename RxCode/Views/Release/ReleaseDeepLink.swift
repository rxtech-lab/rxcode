import Foundation

/// Request to kick off release setup for a repo: start a fresh chat seeded with
/// the release skill so the agent wires up the `.releaserc` + CI workflow.
struct ReleaseSetupRequest: Identifiable, Hashable {
    let id = UUID()
    var projectId: UUID?
    var repoFullName: String?

    init(projectId: UUID? = nil, repoFullName: String? = nil) {
        self.projectId = projectId
        self.repoFullName = repoFullName
    }
}

/// Parses `rxcode://release/setup?repo=<owner/repo>` and
/// `rxcode://release/manage?repo=<owner/repo>` deep links. Returns nil for
/// unrelated URLs.
enum ReleaseDeepLink {
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
        // Accept both rxcode://release/setup and rxcode:release/setup forms.
        let host = url.host
        let firstPath = url.pathComponents.first(where: { $0 != "/" })
        let segment = host ?? firstPath
        guard segment == "release" else { return nil }

        // The action is the path component after the host (e.g. "setup").
        let actionRaw = (host != nil ? url.pathComponents.first(where: { $0 != "/" }) : url.pathComponents.dropFirst().first(where: { $0 != "/" }))
        let action = Action(rawValue: actionRaw ?? "setup") ?? .setup

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let repo = items.first(where: { $0.name == "repo" })?.value?.removingPercentEncoding
        return Parsed(action: action, repoFullName: repo)
    }

    /// Builds the deep link the release banner's button opens.
    static func setupURL(repo: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "release"
        components.path = "/setup"
        components.queryItems = [URLQueryItem(name: "repo", value: repo)]
        return components.url
    }

    static func manageURL(repo: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "release"
        components.path = "/manage"
        components.queryItems = [URLQueryItem(name: "repo", value: repo)]
        return components.url
    }
}
