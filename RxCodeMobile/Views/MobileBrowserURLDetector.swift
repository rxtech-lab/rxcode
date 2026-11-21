import Foundation
import RxCodeSync

enum MobileBrowserURLDetector {
    static func detect(in texts: [String]) -> URL? {
        let candidates = texts.reversed().flatMap(extractURLs)
        return candidates.first(where: isLocalDevURL) ?? candidates.first
    }

    private nonisolated static func extractURLs(from text: String) -> [URL] {
        let pattern = #"https?://[^\s<>"')\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            return URL(string: raw)
        }
    }

    nonisolated static func isLocalDevURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    nonisolated static func desktopProxyBootstrapURL(for url: URL, proxyInfo: MobileWebProxyInfo?) -> URL {
        guard let proxyInfo,
              isLocalDevURL(url),
              url.scheme?.lowercased() == "http"
        else {
            return url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = proxyInfo.host
        components.port = proxyInfo.port
        components.path = "/__rxcode_browser"
        components.queryItems = [
            URLQueryItem(name: "target", value: url.absoluteString),
            URLQueryItem(name: "token", value: proxyInfo.password)
        ]
        return components.url ?? url
    }

    nonisolated static func userFacingURL(
        for url: URL,
        currentDisplayURL: URL?,
        proxyInfo: MobileWebProxyInfo?
    ) -> URL {
        if let bootstrapTarget = reverseBootstrapTargetURL(for: url, proxyInfo: proxyInfo) {
            return bootstrapTarget
        }

        guard isProxyURL(url, proxyInfo: proxyInfo),
              let displayOrigin = currentDisplayURL.flatMap(originURL(for:)),
              isLocalDevURL(displayOrigin)
        else {
            return url
        }

        var components = URLComponents(url: displayOrigin, resolvingAgainstBaseURL: false)
        let proxyComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let proxyPath = proxyComponents?.percentEncodedPath ?? url.path
        components?.percentEncodedPath = proxyPath.isEmpty ? "/" : proxyPath
        components?.percentEncodedQuery = proxyComponents?.percentEncodedQuery
        components?.percentEncodedFragment = proxyComponents?.percentEncodedFragment
        return components?.url ?? displayOrigin
    }

    private nonisolated static func reverseBootstrapTargetURL(for url: URL, proxyInfo: MobileWebProxyInfo?) -> URL? {
        guard let proxyInfo,
              url.host == proxyInfo.host,
              url.port == proxyInfo.port,
              url.path == "/__rxcode_browser",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
              let targetURL = URL(string: target)
        else {
            return nil
        }
        return targetURL
    }

    private nonisolated static func isProxyURL(_ url: URL, proxyInfo: MobileWebProxyInfo?) -> Bool {
        guard let proxyInfo else { return false }
        return url.host == proxyInfo.host && url.port == proxyInfo.port
    }

    private nonisolated static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }
}
