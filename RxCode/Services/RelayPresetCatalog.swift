import Foundation
import Observation
import os.log

/// One hosted relay-server option offered in the Mobile settings tab.
///
/// The canonical list is published as `relays.json` on the RxCode website so
/// new deployments can be advertised without shipping an app update.
struct RelayPreset: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: String
    var description: String?
    var recommended: Bool?

    /// The parsed relay URL, or `nil` if the published value is malformed.
    var relayURL: URL? { URL(string: url) }
}

/// Loads the hosted relay catalog from `code.rxlab.app/relays.json`, falling
/// back to a bundled default so the picker still works offline.
@MainActor
@Observable
final class RelayPresetCatalog {

    static let shared = RelayPresetCatalog()

    private(set) var presets: [RelayPreset] = RelayPresetCatalog.bundledPresets
    private(set) var isLoading = false

    private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "RelayPresets")
    private static let catalogURL = URL(string: "https://code.rxlab.app/relays.json")!

    /// Hardcoded fallback. Keep in sync with `website/public/relays.json`.
    static let bundledPresets: [RelayPreset] = [
        RelayPreset(
            id: "rxlab-hosted",
            name: "RxLab Hosted Relay",
            url: "wss://relaycode.rxlab.app",
            description: "Official end-to-end encrypted relay operated by RxLab. Recommended for most setups.",
            recommended: true
        )
    ]

    /// Fetch the latest catalog. Keeps the current list on any failure.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: Self.catalogURL)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.warning("relay catalog fetch returned non-2xx response")
                return
            }
            let catalog = try JSONDecoder().decode(RelayCatalog.self, from: data)
            let valid = catalog.relays.filter { $0.relayURL != nil }
            if !valid.isEmpty {
                presets = valid
            }
        } catch {
            logger.warning("relay catalog fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct RelayCatalog: Codable {
    let relays: [RelayPreset]
}
