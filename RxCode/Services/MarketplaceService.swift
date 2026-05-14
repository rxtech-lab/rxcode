import Foundation
import RxCodeCore
import os

/// Fetches the marketplace catalog from Anthropic's GitHub repositories
/// and handles plugin installation/uninstallation via Claude Code CLI.
actor MarketplaceService {

    private let logger = Logger(subsystem: "com.claudework", category: "MarketplaceService")

    /// Cached catalog with TTL.
    private var cachedCatalog: [MarketplacePlugin] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

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
                sourceType: sourceType,
                skillPaths: skillPaths
            )
        }
    }

    // MARK: - Installation (via Claude Code CLI)

    /// Retrieve the list of installed plugin names.
    func installedPluginNames() async -> Set<String> {
        let (output, exitCode) = await runCLI(["plugin", "list", "--json"])
        guard exitCode == 0,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return installedPluginNamesFromDisk()
        }
        return Set(json.compactMap { $0["name"] as? String })
    }

    private func installedPluginNamesFromDisk() -> Set<String> {
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

    /// Install a plugin by running `claude plugin install <name>@<marketplace>`
    func installPlugin(_ plugin: MarketplacePlugin) async throws {
        let installArg = "\(plugin.name)@\(plugin.marketplace)"
        let (_, exitCode) = await runCLI(["plugin", "install", installArg])
        guard exitCode == 0 else {
            throw MarketplaceError.installFailed(installArg)
        }
        logger.info("Installed plugin: \(plugin.name, privacy: .public) from \(plugin.marketplace, privacy: .public)")
    }

    /// Uninstall a plugin by running `claude plugin uninstall <name>`
    func uninstallPlugin(_ plugin: MarketplacePlugin) async throws {
        let (_, exitCode) = await runCLI(["plugin", "uninstall", plugin.name])
        guard exitCode == 0 else {
            throw MarketplaceError.uninstallFailed(plugin.name)
        }
        logger.info("Uninstalled plugin: \(plugin.name, privacy: .public)")
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
