import Foundation
import RxCodeExtensionSDK

nonisolated struct ExtensionNetworkRequest: Decodable, Sendable {
    let url: URL
    var method: String?
    var headers: [String: String]?
    var body: Data?
    var credentialSlot: String?

    func request(domains: Set<String>) throws -> URLRequest {
        guard ExtensionRedirectPolicy.permits(url, domains: domains) else { throw ExtensionCallError.permissionDenied }
        let verb = method?.uppercased() ?? "GET"
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(verb) else { throw ExtensionCallError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = verb
        request.httpBody = body
        for (name, value) in headers ?? [:] {
            let restricted = ["host", "authorization", "cookie", "cookie2", "connection", "transfer-encoding",
                              "content-length", "upgrade", "te", "trailer", "expect"]
            guard !restricted.contains(name.lowercased()), !name.lowercased().hasPrefix("proxy-"),
                  name.range(of: #"\A[A-Za-z0-9-]+\z"#, options: .regularExpression) != nil,
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 < 127 }) else {
                throw ExtensionCallError.invalidRequest
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

nonisolated struct ExtensionNetworkResponse: Encodable, Sendable {
    var status: Int
    var body: Data

    static func fetch(_ request: URLRequest, domains: Set<String>) async throws -> Self {
        guard let url = request.url, ExtensionRedirectPolicy.permits(url, domains: domains) else {
            throw ExtensionCallError.permissionDenied
        }
        let policy = ExtensionRedirectPolicy(domains: domains,
            credentialHost: request.value(forHTTPHeaderField: "Authorization") == nil ? nil : request.url?.host?.lowercased())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtensionCallError.invalidRequest }
        // URLSession returns the original 3xx when the delegate refuses a redirect.
        if (300..<400).contains(http.statusCode), http.value(forHTTPHeaderField: "Location") != nil {
            throw ExtensionCallError.permissionDenied
        }
        let limit = 20 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw ExtensionCallError.invalidRequest }
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else { throw ExtensionCallError.invalidRequest }
            body.append(byte)
        }
        return Self(status: http.statusCode, body: body)
    }
}

nonisolated final class ExtensionRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let domains: Set<String>
    let credentialHost: String?

    init(domains: Set<String>, credentialHost: String?) {
        self.domains = domains
        self.credentialHost = credentialHost
    }

    static func permits(_ url: URL, domains: Set<String>) -> Bool {
        guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parsed.scheme?.lowercased() == "https", let host = parsed.host?.lowercased(),
              parsed.user == nil, parsed.password == nil, parsed.port == nil || parsed.port == 443 else { return false }
        return domains.contains(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, Self.permits(url, domains: domains),
              credentialHost == nil || url.host?.lowercased() == credentialHost else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
