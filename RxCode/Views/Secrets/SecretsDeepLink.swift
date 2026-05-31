import Foundation

/// Request to present the secret-setup form, carrying optional context so the
/// sheet can pin the right repo and pre-detect the relevant local file.
struct SecretsSetupRequest: Identifiable, Hashable {
    let id = UUID()
    var repoFullName: String?
    var projectPath: String?
    /// The local filename that triggered the prompt (e.g. `.env`), if any.
    var filename: String?
}

/// Parses `rxcode://secrets/add?repo=<owner/repo>&path=<dir>&file=<name>` deep
/// links into a `SecretsSetupRequest`. Returns nil for unrelated URLs.
enum SecretsDeepLink {
    static let scheme = "rxcode"

    static func parse(_ url: URL) -> SecretsSetupRequest? {
        guard url.scheme == scheme else { return nil }
        // Accept both rxcode://secrets/add and rxcode:secrets/add forms.
        let host = url.host
        let firstPath = url.pathComponents.first(where: { $0 != "/" })
        let segment = host ?? firstPath
        guard segment == "secrets" else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?.removingPercentEncoding
        }
        return SecretsSetupRequest(
            repoFullName: value("repo"),
            projectPath: value("path"),
            filename: value("file")
        )
    }

    /// Builds the deep link the banner's button opens.
    static func addURL(repo: String, path: String?, file: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "secrets"
        components.path = "/add"
        var query: [URLQueryItem] = [URLQueryItem(name: "repo", value: repo)]
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        if let file { query.append(URLQueryItem(name: "file", value: file)) }
        components.queryItems = query
        return components.url
    }
}
