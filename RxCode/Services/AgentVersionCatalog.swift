import Foundation
import RxCodeCore

/// Published versions for agent packages. The registry's current release is
/// still supplied by the caller when package metadata is unavailable.
actor AgentVersionCatalog {
    enum Source: Hashable, Sendable {
        case npm(String)
        case pypi(String)
    }

    enum CatalogError: LocalizedError {
        case unsupportedDistribution
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedDistribution:
                "This client does not publish selectable package versions."
            case .invalidResponse:
                "Could not load published versions."
            }
        }
    }

    static let shared = AgentVersionCatalog()

    private var cache: [Source: (date: Date, versions: [String])] = [:]
    private let cacheLifetime: TimeInterval = 3600

    func versions(for runtime: AgentRuntimeInstaller.Runtime) async throws -> [String] {
        try await versions(from: .npm(runtime.package))
    }

    func versions(for agent: ACPRegistryAgent) async throws -> [String] {
        if let distribution = agent.distribution.npx,
           let pinned = ACPPackageVersion.npx(distribution.package, version: agent.version) {
            let name = String(pinned.dropLast(agent.version.count + 1))
            return try await versions(from: .npm(name))
        }
        if let distribution = agent.distribution.uvx,
           let pinned = ACPPackageVersion.uvx(distribution.package, version: agent.version) {
            let name = String(pinned.dropLast(agent.version.count + 1))
            return try await versions(from: .pypi(name))
        }
        throw CatalogError.unsupportedDistribution
    }

    private func versions(from source: Source) async throws -> [String] {
        if let cached = cache[source], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.versions
        }

        let url: URL
        switch source {
        case .npm(let name):
            url = try packageURL(base: "https://registry.npmjs.org", name: name)
        case .pypi(let name):
            url = try packageURL(base: "https://pypi.org/pypi", name: name, suffix: "json")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if case .npm = source {
            request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CatalogError.invalidResponse }

        let published: [String]
        switch source {
        case .npm:
            published = Array((object["versions"] as? [String: Any] ?? [:]).keys)
        case .pypi:
            published = Array((object["releases"] as? [String: Any] ?? [:]).keys)
        }
        let result = published
            .filter { ACPPackageVersion.isValid($0) && !$0.contains("-") && !$0.contains("+") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard !result.isEmpty else { throw CatalogError.invalidResponse }
        cache[source] = (Date(), result)
        return result
    }

    private func packageURL(base: String, name: String, suffix: String? = nil) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CatalogError.invalidResponse
        }
        let path = suffix.map { "\(base)/\(encoded)/\($0)" } ?? "\(base)/\(encoded)"
        guard let url = URL(string: path) else { throw CatalogError.invalidResponse }
        return url
    }
}
