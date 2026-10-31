import Foundation

/// A catalog selection only; opening this link never starts a download.
nonisolated struct LocalModelSheetRequest: Identifiable, Equatable {
    let repoID: String
    let format: LocalModelWeightFormat
    var id: String { "\(format.rawValue):\(repoID)" }

    var url: URL {
        var components = URLComponents()
        components.scheme = "rxcode"
        components.host = "models"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "repo", value: repoID), URLQueryItem(name: "format", value: format.rawValue)]
        return components.url!
    }

    static func parse(_ url: URL) -> Self? {
        guard url.scheme == "rxcode", url.host == "models", url.path == "/open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let repo = items.first(where: { $0.name == "repo" })?.value,
              let rawFormat = items.first(where: { $0.name == "format" })?.value,
              let format = LocalModelWeightFormat(rawValue: rawFormat) else { return nil }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return Self(repoID: repo, format: format)
    }
}
