import Foundation
import RxCodeCore
import os

/// Fetches skill/plugin catalogs and keeps RxCode-owned install state.
/// Provider-specific config is materialized at launch time where possible.
actor MarketplaceService {

    private let logger = Logger(subsystem: "com.claudework", category: "MarketplaceService")
    enum CustomSourceError: LocalizedError {
        case invalidGitHubURL
        case duplicateSource

        var errorDescription: String? {
            switch self {
            case .invalidGitHubURL:
                return "Enter a GitHub repository URL such as https://github.com/owner/repo."
            case .duplicateSource:
                return "This Git source is already included."
            }
        }
    }

    /// Cached catalog with TTL.
    private var cachedCatalog: [MarketplacePlugin] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    private let configURL: URL

    init(baseURL: URL = AppSupport.bundleScopedURL) {
        self.configURL = baseURL.appendingPathComponent("skills.json")
    }

    /// Source repositories to scan.
    private static let sourceRepos: [(owner: String, repo: String, defaultCategory: String)] = [
        ("anthropics", "claude-plugins-official", "official"),
        ("anthropics", "skills", "agent-skills"),
        ("anthropics", "knowledge-work-plugins", "knowledge-work"),
        ("anthropics", "financial-services-plugins", "financial-services"),
    ]
    private static let openAISkillsSource = MarketplaceSource(owner: "openai", repo: "skills")

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
            group.addTask {
                await self.fetchOpenAISkills()
            }
            let customSources = loadCustomSources()
            let repoSources = Self.sourceRepos.map {
                (source: MarketplaceSource(owner: $0.owner, repo: $0.repo), defaultCategory: $0.defaultCategory)
            } + customSources.map {
                (source: $0.source, defaultCategory: $0.defaultCategory)
            }

            for source in repoSources {
                group.addTask {
                    await self.fetchRepoPlugins(
                        source: source.source,
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

    private func fetchOpenAISkills() async -> [MarketplacePlugin] {
        let apiURL = "https://api.github.com/repos/openai/skills/contents/skills/.curated?ref=main"
        guard let url = URL(string: apiURL) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }

            let names = entries.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "dir" else { return nil }
                return entry["name"] as? String
            }

            var skills: [MarketplacePlugin] = []
            await withTaskGroup(of: MarketplacePlugin?.self) { group in
                for name in names {
                    group.addTask { await self.fetchOpenAISkill(named: name) }
                }
                for await skill in group {
                    if let skill { skills.append(skill) }
                }
            }
            return skills
        } catch {
            logger.warning("Failed to fetch OpenAI skills catalog: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchOpenAISkill(named name: String) async -> MarketplacePlugin? {
        let path = "skills/.curated/\(name)"
        guard let instructions = await fetchRawSkillInstructions(source: Self.openAISkillsSource, path: path) else {
            return nil
        }

        let metadata = parseSkillMetadata(instructions)
        return MarketplacePlugin(
            name: metadata.name ?? name,
            description: metadata.description ?? "",
            author: "OpenAI",
            category: "codex-curated",
            homepage: "https://github.com/openai/skills/tree/main/\(path)",
            marketplace: "openai-skills-curated",
            marketplaceSource: Self.openAISkillsSource,
            sourceType: .agentSkill,
            skillPaths: [path]
        )
    }

    // MARK: - Fetch Repository

    private func fetchRepoPlugins(source: MarketplaceSource, defaultCategory: String) async -> [MarketplacePlugin] {
        let ref = source.ref?.isEmpty == false ? source.ref! : "main"
        let catalogURL = "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/\(ref)/.claude-plugin/marketplace.json"
        guard let url = URL(string: catalogURL) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            return parseMarketplaceCatalog(data: data, source: source, defaultCategory: defaultCategory)
        } catch {
            logger.warning("Failed to fetch catalog from \(source.codexSource, privacy: .public): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parse Catalog

    private func parseMarketplaceCatalog(data: Data, source: MarketplaceSource, defaultCategory: String) -> [MarketplacePlugin] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marketplaceName = json["name"] as? String,
              let plugins = json["plugins"] as? [[String: Any]] else {
            return []
        }

        let ownerInfo = json["owner"] as? [String: Any]
        let defaultAuthor = ownerInfo?["name"] as? String ?? source.owner

        let marketplaceSource = source

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

    // MARK: - Custom Git Sources

    func customSources() -> [MarketplaceCustomSource] {
        loadCustomSources()
    }

    func addCustomGitSource(url rawURL: String, ref rawRef: String? = nil) throws -> MarketplaceCustomSource {
        let source = try parseGitHubSource(url: rawURL, ref: rawRef)
        let normalizedSource = MarketplaceCustomSource(source: source)
        var config = try loadConfig()

        let builtInSources = Self.sourceRepos.map { MarketplaceSource(owner: $0.owner, repo: $0.repo) }
        if builtInSources.contains(where: { sameSource($0, source) }) ||
            config.customSources.contains(where: { sameSource($0.source, source) }) {
            throw CustomSourceError.duplicateSource
        }

        config.customSources.append(normalizedSource)
        try saveConfig(config)
        cachedCatalog = []
        cacheDate = nil
        return normalizedSource
    }

    func removeCustomGitSource(_ source: MarketplaceCustomSource) throws {
        var config = try loadConfig()
        config.customSources.removeAll { $0.id == source.id }
        try saveConfig(config)
        cachedCatalog = []
        cacheDate = nil
    }

    private func loadCustomSources() -> [MarketplaceCustomSource] {
        (try? loadConfig().customSources) ?? []
    }

    private func parseGitHubSource(url rawURL: String, ref rawRef: String?) throws -> MarketplaceSource {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = rawRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitRef = ref?.isEmpty == false ? ref : nil

        if let match = regexMatch(trimmed, #"^git@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#) {
            return MarketplaceSource(owner: match[0], repo: match[1], ref: explicitRef)
        }

        if let match = regexMatch(trimmed, #"^https?://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#) {
            return MarketplaceSource(owner: match[0], repo: match[1], ref: explicitRef)
        }

        if let match = regexMatch(trimmed, #"^https?://github\.com/([^/\s]+)/([^/\s]+)/tree/([^/\s]+)(?:/.*)?$"#) {
            return MarketplaceSource(owner: match[0], repo: match[1], ref: explicitRef ?? match[2])
        }

        if let match = regexMatch(trimmed, #"^([^/\s]+)/([^/\s@]+)(?:@([^/\s]+))?$"#) {
            let parsedRef = match.count > 2 && !match[2].isEmpty ? match[2] : nil
            return MarketplaceSource(owner: match[0], repo: match[1], ref: explicitRef ?? parsedRef)
        }

        throw CustomSourceError.invalidGitHubURL
    }

    private func regexMatch(_ value: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.range.location != NSNotFound else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }

    private func sameSource(_ lhs: MarketplaceSource, _ rhs: MarketplaceSource) -> Bool {
        lhs.owner.lowercased() == rhs.owner.lowercased() &&
            lhs.repo.lowercased() == rhs.repo.lowercased() &&
            normalizedRef(lhs.ref) == normalizedRef(rhs.ref)
    }

    private func normalizedRef(_ ref: String?) -> String {
        let trimmed = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "main"
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
            for plugin in catalog where installedNames.contains(plugin.name) {
                if let index = config.plugins.firstIndex(where: { $0.id == plugin.id }) {
                    var shouldFetchInstructions = config.plugins[index].instructions == nil
                    if config.plugins[index].summary != plugin.description {
                        config.plugins[index].summary = plugin.description
                        changed = true
                    }
                    if config.plugins[index].category != plugin.category {
                        config.plugins[index].category = plugin.category
                        changed = true
                    }
                    if config.plugins[index].marketplaceSource != plugin.marketplaceSource {
                        config.plugins[index].marketplaceSource = plugin.marketplaceSource
                        changed = true
                    }
                    if config.plugins[index].sourceType != plugin.sourceType {
                        config.plugins[index].sourceType = plugin.sourceType
                        changed = true
                    }
                    if config.plugins[index].skillPaths != plugin.skillPaths {
                        config.plugins[index].skillPaths = plugin.skillPaths
                        shouldFetchInstructions = true
                        changed = true
                    }
                    if shouldFetchInstructions,
                       let instructions = await skillInstructions(for: plugin) {
                        config.plugins[index].instructions = instructions
                        changed = true
                    }
                } else {
                    config.plugins.append(MarketplacePluginRecord(
                        name: plugin.name,
                        marketplace: plugin.marketplace,
                        summary: plugin.description,
                        category: plugin.category,
                        marketplaceSource: plugin.marketplaceSource,
                        sourceType: plugin.sourceType,
                        skillPaths: plugin.skillPaths,
                        instructions: await skillInstructions(for: plugin)
                    ))
                    changed = true
                }
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
        let instructions = await skillInstructions(for: plugin)
        let record = MarketplacePluginRecord(
            name: plugin.name,
            marketplace: plugin.marketplace,
            summary: plugin.description,
            category: plugin.category,
            marketplaceSource: plugin.marketplaceSource,
            sourceType: plugin.sourceType,
            skillPaths: plugin.skillPaths,
            instructions: instructions
        )

        if let index = config.plugins.firstIndex(where: { $0.id == record.id }) {
            config.plugins[index].isGloballyEnabled = true
            config.plugins[index].enabledProviders = Set(AgentProvider.allCases)
            config.plugins[index].marketplaceSource = plugin.marketplaceSource
            config.plugins[index].summary = plugin.description
            config.plugins[index].category = plugin.category
            config.plugins[index].sourceType = plugin.sourceType
            config.plugins[index].skillPaths = plugin.skillPaths
            config.plugins[index].instructions = instructions
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
                    // Codex's `source_type` enum only accepts `git` or `local`.
                    pairs += ["-c", "\(marketplaceKey).source_type=\(tomlString("git"))"]
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

            var lines = ["# Installed RxCode skills\nUse the following installed skills when they match the user's request."]
            var remainingBudget = 18_000
            for record in records {
                let detail = (record.instructions ?? record.summary)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let clipped = String(detail.prefix(max(0, min(remainingBudget, 6_000))))
                if detail.isEmpty {
                    lines.append("## \(record.name)\nSource: \(record.marketplace)")
                } else {
                    lines.append("## \(record.name)\nSource: \(record.marketplace)\n\n\(clipped)")
                    remainingBudget -= clipped.count
                    if remainingBudget <= 0 { break }
                }
            }
            return lines.joined(separator: "\n\n")
        } catch {
            logger.warning("Failed to build skill prompt context: \(error.localizedDescription)")
            return nil
        }
    }

    private func skillInstructions(for plugin: MarketplacePlugin) async -> String? {
        guard let source = plugin.marketplaceSource else { return nil }
        for path in plugin.skillPaths {
            if let instructions = await fetchRawSkillInstructions(source: source, path: path) {
                return instructions
            }
        }
        return nil
    }

    private func fetchRawSkillInstructions(source: MarketplaceSource, path: String) async -> String? {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ref = source.ref?.isEmpty == false ? source.ref! : "main"
        let rawURL = "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/\(ref)/\(cleanPath)/SKILL.md"
        guard let url = URL(string: rawURL) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            logger.warning("Failed to fetch skill instructions at \(rawURL, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    private func parseSkillMetadata(_ text: String) -> (name: String?, description: String?) {
        guard text.hasPrefix("---"),
              let end = text.dropFirst(3).range(of: "---") else {
            return (nil, nil)
        }

        let frontMatter = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
        var name: String?
        var description: String?
        for rawLine in frontMatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name:") {
                name = cleanYAMLScalar(String(line.dropFirst("name:".count)))
            } else if line.hasPrefix("description:") {
                description = cleanYAMLScalar(String(line.dropFirst("description:".count)))
            }
        }
        return (name, description)
    }

    private func cleanYAMLScalar(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           let first = trimmed.first,
           let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
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
