#if os(macOS)
import Foundation
import RxCodeCore
import RxCodeExtensionDistribution

public struct CatalogExtensionRelease: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let pluginApi: String
    public let size: Int
    public let sha256: String
    public let signatureFormat: String
    public let signature: String
    public let keyId: String
    public let cdhashes: String

    public var envelope: ExtensionReleaseEnvelope {
        ExtensionReleaseEnvelope(keyId: keyId, id: id, version: version, pluginApi: pluginApi,
                                 sha256: sha256, cdhashes: cdhashes, signature: signature, format: signatureFormat)
    }
}

public protocol ExtensionCatalog: Sendable {
    func releases() async throws -> [CatalogExtensionRelease]
    func download(_ release: CatalogExtensionRelease, to file: URL) async throws
    func revocations() async throws -> (Data, HTTPURLResponse)
}

public struct FlowcyExtensionCatalog: ExtensionCatalog {
    private let base: URL
    private let session: URLSession
    public init() {
        base = URL(string: "https://www.flowcy.dev/api/v1/extensions")!
        session = Self.session()
    }

    #if DEBUG
    public init(testBaseURL: URL) {
        base = testBaseURL
        session = Self.session()
    }
    #endif

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }

    public func releases() async throws -> [CatalogExtensionRelease] {
        struct Catalog: Decodable { let extensions: [CatalogExtensionRelease] }
        let (data, response) = try await read(base.appending(queryItems: [URLQueryItem(name: "pluginApi", value: ExtensionManifest.apiVersion)]),
                                              maximum: 2 * 1024 * 1024)
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Catalog.self, from: data).extensions
    }

    public func revocations() async throws -> (Data, HTTPURLResponse) {
        try await read(base.appending(path: "revocations"), maximum: 1024 * 1024)
    }

    public func download(_ release: CatalogExtensionRelease, to file: URL) async throws {
        try ExtensionCatalogService.validateID(release.id)
        guard release.version.range(of: #"\A[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)*\z"#, options: .regularExpression) != nil,
              (1...ExtensionReleaseVerifier.maximumArchiveBytes).contains(release.size) else {
            throw ExtensionVerificationError.invalidPayload
        }
        let url = base.appending(component: release.id).appending(path: "releases")
            .appending(component: release.version).appending(path: "download")
        let (data, response) = try await read(url, maximum: release.size)
        guard response.statusCode == 200, data.count == release.size else { throw URLError(.badServerResponse) }
        try data.write(to: file, options: .withoutOverwriting)
    }

    private func read(_ url: URL, maximum: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, raw) = try await session.bytes(from: url)
        guard let response = raw as? HTTPURLResponse, response.expectedContentLength <= maximum else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        // Catalog responses and private bucket redirects only carry unsigned transport metadata.
        guard response.url?.scheme == base.scheme else { throw URLError(.secureConnectionFailed) }
        var result = Data()
        for try await byte in bytes {
            guard result.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
            result.append(byte)
        }
        return (result, response)
    }
}
#endif
