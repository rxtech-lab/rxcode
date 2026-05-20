import Foundation
import RxCodeCore
import os

/// Fetches skill/plugin catalogs and keeps RxCode-owned install state.
/// Provider-specific config is materialized at launch time where possible.
actor MarketplaceService {

    private let logger = Logger(subsystem: "com.claudework", category: "MarketplaceService")

    /// Cached catalog with TTL.
    private var cachedCatalog: [MarketplacePlugin] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    private let configURL = AppSupport.bundleScopedURL.appendingPathComponent("skills.json")

    /// Source repositories to scan.
    private static let sourceRepos: [(owner: String, repo: String, defaultCategory: String)] = [
        ("anthropics", "claude-plugins-official", "official"),
        ("anthropics", "skills", "agent-skills"),
        ("anthropics", "knowledge-work-plugins", "knowledge-work"),
        ("anthropics", "financial-services-plugins", "financial-services"),
    ]

    // MARK: - Fetch Catalog

    func fetchCatalog(forceRefresh: Bool = false) async -> [MarketplacePlugin] {
        if !forceRefresh,
           let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL,
           !cachedCatalog.isEmpty {
            return cachedCatalog
        }

        var allPlugins: [MarketplacePlugin] = []

        await withTaskGroup(of: [MarketplacePlugin].self) { group in
            for source in Self.sourceRepos {
                group.addTask {
                    await self.fetchRepoPlugins(
                        owner: source.owner,
                        repo: source.repo,
                        defaultCategory: source.defaultCategory
                    )
                }
            }
            for await plugins in group {
                allPlugins.append(contentsOf: plugins)
            }
        }

        allPlugins.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cachedCatalog = allPlugins
        cacheDate = Date()

        logger.info("Fetched \(allPlugins.count) plugins from marketplace")
        return allPlugins
    }

    // MARK: - Fetch Repository

    private func fetchRepoPlugins(owner: String, repo: String, defaultCategory: String) async -> [MarketplacePlugin] {
        let catalogURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/main/.claude-plugin/marketplace.json"
        guard let url = URL(string: catalogURL) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            return parseMarketplaceCatalog(data: data, owner: owner, repo: repo, defaultCategory: defaultCategory)
        } catch {
            logger.warning("Failed to fetch catalog from \(owner)/\(repo): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parse Catalog

    private func parseMarketplaceCatalog(data: Data, owner: String, repo: String, defaultCategory: String) -> [MarketplacePlugin] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marketplaceName = json["name"] as? String,
              let plugins = json["plugins"] as? [[String: Any]] else {
            return []
        }

        let ownerInfo = json["owner"] as? [String: Any]
        let defaultAuthor = ownerInfo?["name"] as? String ?? owner

        let marketplaceSource = MarketplaceSource(owner: owner, repo: repo)

        return plugins.compactMap { entry -> MarketplacePlugin? in
            guard let name = entry["name"] as? String else { return nil }

            let description = entry["description"] as? String ?? ""
            let category = entry["category"] as? String ?? defaultCategory
            let homepage = entry["homepage"] as? String ?? ""

            // author: string or { "name": "..." } object
            let author: String
            if let authorDict = entry["author"] as? [String: Any] {
                author = authorDict["name"] as? String ?? defaultAuthor
            } else if let authorStr = entry["author"] as? String {
                author = authorStr
            } else {
                author = defaultAuthor
            }

            // Parse source: string (local path) or object (url/git-subdir)
            let sourceType: MarketplacePlugin.SourceType
            let skillPaths: [String]

            if let skills = entry["skills"] as? [String], !skills.isEmpty {
                // skills repository: bundle format
                sourceType = .skillsBundle
                skillPaths = skills
            } else if let sourceDict = entry["source"] as? [String: Any] {
                // Object form: {"source": "url", "url": "..."} or {"source": "git-subdir", ...}
                let sourceStr = sourceDict["source"] as? String ?? "url"
                sourceType = MarketplacePlugin.SourceType(rawValue: sourceStr) ?? .url
                skillPaths = []
            } else {
                // String form: local path such as "./plugins/name"
                sourceType = .local
                skillPaths = []
            }

            return MarketplacePlugin(
                name: name,
                description: description,
                author: author,
                category: category,
                homepage: homepage,
                marketplace: marketplaceName,
                marketplaceSource: marketplaceSource,
                sourceType: sourceType,
                skillPaths: skillPaths
            )
        }
    }

    // MARK: - Installation

    /// Retrieve installed plugin names from RxCode state, plus legacy Claude installs.
    func installedPluginNames() async -> Set<String> {
        var names = Set((try? loadConfig().plugins.map(\.name)) ?? [])
        names.formUnion(await installedClaudePluginNames())
        return names
    }

    private func installedClaudePluginNames() async -> Set<String> {
        let (output, exitCode) = await runCLI(["plugin", "list", "--json"])
        guard exitCode == 0,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return installedClaudePluginNamesFromDisk()
        }
        return Set(json.compactMap { $0["name"] as? String })
    }

    private func installedClaudePluginNamesFromDisk() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var names: Set<String> = []
        for dir in ["\(home)/.claude/plugins", "\(home)/.claude/skills"] {
            if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                names.formUnion(entries.filter { !$0.hasPrefix(".") })
            }
        }
        return names
    }

    func importInstalledPlugins(catalog: [MarketplacePlugin], installedNames: Set<String>) async {
        do {
            var config = try loadConfig()
            var changed = false
            let existingIds = Set(config.plugins.map(\.id))

            for plugin in catalog where installedNames.contains(plugin.name) && !existingIds.contains(plugin.id) {
                config.plugins.append(MarketplacePluginRecord(
                    name: plugin.name,
                    marketplace: plugin.marketplace,
                    summary: plugin.description,
                    category: plugin.category,
                    marketplaceSource: plugin.marketplaceSource
                ))
                changed = true
            }

            if changed {
                try saveConfig(config)
            }
        } catch {
            logger.warning("Failed to import installed marketplace plugins: \(error.localizedDescription)")
        }
    }

    /// Install into RxCode-owned state and mirror to Claude Code when available.
    func installPlugin(_ plugin: MarketplacePlugin) async throws {
        var config = try loadConfig()
        let record = MarketplacePluginRecord(
            name: plugin.name,
            marketplace: plugin.marketplace,
            summary: plugin.description,
            category: plugin.category,
            marketplaceSource: plugin.marketplaceSource
        )

        if let index = config.plugins.firstIndex(where: { $0.id == record.id }) {
            config.plugins[index].isGloballyEnabled = true
            config.plugins[index].enabledProviders = Set(AgentProvider.allCases)
            config.plugins[index].marketplaceSource = plugin.marketplaceSource
            config.plugins[index].summary = plugin.description
            config.plugins[index].category = plugin.category
        } else {
            config.plugins.append(record)
        }
        try saveConfig(config)

        let installArg = "\(plugin.name)@\(plugin.marketplace)"
        let (_, exitCode) = await runCLI(["plugin", "install", installArg])
        if exitCode != 0 {
            logger.warning("Claude plugin mirror install failed for \(installArg, privacy: .public)")
        }
        logger.info("Installed skill: \(plugin.name, privacy: .public) from \(plugin.marketplace, privacy: .public)")
    }

    /// Remove from RxCode-owned state and mirror to Claude Code when available.
    func uninstallPlugin(_ plugin: MarketplacePlugin) async throws {
        var config = try loadConfig()
        config.plugins.removeAll { $0.id == plugin.id || $0.name == plugin.name }
        try saveConfig(config)

        let (_, exitCode) = await runCLI(["plugin", "uninstall", plugin.name])
        if exitCode != 0 {
            logger.warning("Claude plugin mirror uninstall failed for \(plugin.name, privacy: .public)")
        }
        logger.info("Uninstalled skill: \(plugin.name, privacy: .public)")
    }

    func codexConfigOverrides() async -> [String] {
        do {
            let config = try loadConfig()
            let records = config.plugins
                .filter { $0.isEnabled(for: .codex) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            var pairs: [String] = []
            var emittedMarketplaces: Set<String> = []

            for record in records {
                if let source = record.marketplaceSource,
                   !emittedMarketplaces.contains(record.marketplace) {
                    emittedMarketplaces.insert(record.marketplace)
                    let marketplaceKey = "marketplaces.\(tomlKey(record.marketplace))"
                    pairs += ["-c", "\(marketplaceKey).source_type=\(tomlString("github"))"]
                    pairs += ["-c", "\(marketplaceKey).source=\(tomlString(source.codexSource))"]
                }

                let pluginId = "\(record.name)@\(record.marketplace)"
                pairs += ["-c", "plugins.\(tomlKey(pluginId)).enabled=true"]
            }
            if !pairs.isEmpty {
                pairs = ["--enable", "plugins"] + pairs
            }
            return pairs
        } catch {
            logger.warning("Failed to build Codex skill overrides: \(error.localizedDescription)")
            return []
        }
    }

    func promptContext(for provider: AgentProvider) async -> String? {
        do {
            let records = try loadConfig().plugins
                .filter { $0.isEnabled(for: provider) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !records.isEmpty else { return nil }

            var lines = ["Installed RxCode skills available for this session:"]
            for record in records {
                let detail = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if detail.isEmpty {
                    lines.append("- \(record.name) from \(record.marketplace)")
                } else {
                    lines.append("- \(record.name) from \(record.marketplace): \(detail)")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            logger.warning("Failed to build skill prompt context: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - RxCode Config

    private func loadConfig() throws -> MarketplacePluginConfiguration {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: configURL.path) else {
            return MarketplacePluginConfiguration()
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(MarketplacePluginConfiguration.self, from: data)
    }

    private func saveConfig(_ config: MarketplacePluginConfiguration) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    // MARK: - CLI Runner

    private func runCLI(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ProcessInfo.processInfo.environment

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (error.localizedDescription, 1))
            }
        }
    }

    private func tomlKey(_ key: String) -> String {
        if key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return key
        }
        return tomlString(key)
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - Errors

    enum MarketplaceError: LocalizedError {
        case installFailed(String)
        case uninstallFailed(String)

        var errorDescription: String? {
            switch self {
            case .installFailed(let name): return "Plugin installation failed: \(name)"
            case .uninstallFailed(let name): return "Plugin uninstallation failed: \(name)"
            }
        }
    }
}
