import Foundation

public struct ExtensionHTTPResponse: Codable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public extension RxCodeHost {
    /// The broker resolves the named credential slot after checking the destination domain.
    func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
               credentialSlot: String? = nil) async throws -> ExtensionHTTPResponse {
        let request = ExtensionHTTPRequest(url: url, method: method, headers: headers, body: body, credentialSlot: credentialSlot)
        return try await call(.netFetch, request, returning: ExtensionHTTPResponse.self)
    }
}

private struct ExtensionHTTPRequest: Encodable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
    let credentialSlot: String?
}
