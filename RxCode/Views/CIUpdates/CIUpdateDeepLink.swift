import Foundation

/// Request to present the CI auto-update manage sheet pinned to a repo, so the
/// banner can skip the repo picker and drop the user straight into that repo's
/// detail (or its add flow when it isn't watched yet).
struct CISetupRequest: Identifiable, Hashable {
    let id = UUID()
    var repoFullName: String?
    var projectPath: String?
}

/// Parses `rxcode://ci/add?repo=<owner/repo>&path=<dir>` deep links into a
/// `CISetupRequest`. Returns nil for unrelated URLs. Mirrors `SecretsDeepLink`.
enum CIUpdateDeepLink {
    static let scheme = "rxcode"

    static func parse(_ url: URL) -> CISetupRequest? {
        guard url.scheme == scheme else { return nil }
        // Accept both rxcode://ci/add and rxcode:ci/add forms.
        let host = url.host
        let firstPath = url.pathComponents.first(where: { $0 != "/" })
        let segment = host ?? firstPath
        guard segment == "ci" else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?.removingPercentEncoding
        }
        return CISetupRequest(
            repoFullName: value("repo"),
            projectPath: value("path")
        )
    }

    /// Builds the deep link the CI setup banner's button opens.
    static func addURL(repo: String, path: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "ci"
        components.path = "/add"
        var query: [URLQueryItem] = [URLQueryItem(name: "repo", value: repo)]
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        components.queryItems = query
        return components.url
    }
}
