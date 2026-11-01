import Foundation
import struct RxCodeCore.DecisionResult

/// Keyless web search for the decision studio: DuckDuckGo's HTML endpoint,
/// read as titles, links and snippets. Pages themselves are not fetched; the
/// snippets are the context a decision model judges with.
nonisolated enum WebSearchClient {
    enum SearchError: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let status): "The web search returned HTTP \(status)."
            }
        }
    }

    static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!

    static func search(_ query: String, limit: Int) async throws -> [DecisionResult.Source] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // The endpoint serves an empty page to clients without a browser agent.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SearchError.http(http.statusCode)
        }
        return Array(parse(String(decoding: data, as: UTF8.self)).prefix(limit))
    }

    /// Results in page order; ads (`result--ad`) are skipped.
    static func parse(_ html: String) -> [DecisionResult.Source] {
        // Each result is a `<div class="result results_links … ">` container.
        let blocks = html.components(separatedBy: #"<div class="result "#).dropFirst()
        let titlePattern = #/class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>/#.dotMatchesNewlines()
        let snippetPattern = #/class="result__snippet"[^>]*>(.*?)</a>/#.dotMatchesNewlines()
        var seen = Set<String>()
        var results: [DecisionResult.Source] = []
        for block in blocks where !block.contains("result--ad") {
            guard let title = block.firstMatch(of: titlePattern) else { continue }
            let url = resolve(String(title.output.1))
            guard url.hasPrefix("http"), seen.insert(url).inserted else { continue }
            let snippet = block.firstMatch(of: snippetPattern).map { plainText(String($0.output.1)) } ?? ""
            results.append(.init(title: plainText(String(title.output.2)), url: url, snippet: snippet))
        }
        return results
    }

    /// Redirect links (`//duckduckgo.com/l/?uddg=<url>`) unwrap to the target.
    static func resolve(_ href: String) -> String {
        let decoded = decodeEntities(href)
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        if let components = URLComponents(string: absolute), components.path == "/l/",
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return absolute
    }

    static func plainText(_ html: String) -> String {
        let stripped = html.replacing(#/<[^>]+>/#, with: "")
        return decodeEntities(stripped)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
