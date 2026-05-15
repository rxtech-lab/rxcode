import Foundation
import RxCodeCore
import os

/// Fetches the official Agent Client Protocol registry and caches it locally.
/// Mirrors the pattern in `MarketplaceService`.
actor ACPRegistryService {

    private let logger = Logger(subsystem: "com.claudework", category: "ACPRegistryService")

    static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    private var cached: ACPRegistry?
    private var cacheDate: Date?
    /// 1 hour — registry rarely changes but stale entries are harmless.
    private let cacheTTL: TimeInterval = 3600

    init() {}

    /// Returns the cached registry if fresh, otherwise fetches.
    /// Returns nil only if both the network fetch and the on-disk snapshot fail.
    func fetchRegistry(forceRefresh: Bool = false, snapshotURL: URL? = nil) async -> ACPRegistry? {
        if !forceRefresh, let cached, let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL {
            return cached
        }

        if let registry = await downloadRegistry() {
            cached = registry
            cacheDate = Date()
            if let snapshotURL {
                writeSnapshot(registry, to: snapshotURL)
            }
            logger.info("Fetched ACP registry: \(registry.agents.count) agents")
            return registry
        }

        // Network failure — fall back to disk snapshot.
        if let snapshotURL, let snapshot = readSnapshot(from: snapshotURL) {
            cached = snapshot
            cacheDate = Date()
            logger.warning("ACP registry fetch failed; using on-disk snapshot")
            return snapshot
        }

        return cached
    }

    private func downloadRegistry() async -> ACPRegistry? {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.registryURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.warning("ACP registry HTTP failure: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let decoder = JSONDecoder()
            return try decoder.decode(ACPRegistry.self, from: data)
        } catch {
            logger.warning("ACP registry decode/fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Snapshot Persistence

    private func writeSnapshot(_ registry: ACPRegistry, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(registry)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("ACP snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readSnapshot(from url: URL) -> ACPRegistry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ACPRegistry.self, from: data)
    }
}
