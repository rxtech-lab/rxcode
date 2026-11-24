import Foundation
import SwiftUI
import RxCodeCore
import RxCodeExtensionBuild

extension AppState {
    var usagePluginRegistry: UsagePluginRegistry { usagePlugins.registry }
    var usageDashboard: UsageDashboard {
        get { usagePlugins.dashboard }
        set { usagePlugins.dashboard = newValue }
    }
    var usageDashboardError: String? {
        get { usagePlugins.error }
        set { usagePlugins.error = newValue }
    }
    var usagePluginsRefreshing: Bool {
        get { usagePlugins.refreshing }
        set { usagePlugins.refreshing = newValue }
    }
    var usagePluginsRefreshPending: Bool {
        get { usagePlugins.refreshPending }
        set { usagePlugins.refreshPending = newValue }
    }
    var usagePluginRefreshTask: Task<Void, Never>? {
        get { usagePlugins.refreshTask }
        set { usagePlugins.refreshTask = newValue }
    }

    static let usagePluginIDs = ["acp-opencode", "acp-antigravity", "ai-usage", "ai-limits", "vercel", "neon", "turso", "cloudflare", "github-ci"]

    private func registerBuiltInUsagePlugins() async {
        for id in ["vercel", "neon", "turso", "cloudflare"] {
            await usagePluginRegistry.register(CloudUsagePlugin(id: id, gatewayCredential: { integrationID in
                await UsageDashboardStore.shared.gatewayCredential(for: integrationID)
            }, billingCredential: { integrationID in
                await UsageDashboardStore.shared.billingCredential(for: integrationID)
            }))
        }
        await usagePluginRegistry.register(GitHubCIUsagePlugin())
        for provider in ACPUsageProvider.allCases {
            await usagePluginRegistry.register(LocalUsagePlugin(id: provider.pluginID, title: provider.title) { [weak self] integration in
                guard let self,
                      let client = await self.acpClients.first(where: { $0.id == integration.resource }) else {
                    throw ACPUsageError.unavailable
                }
                return try await ACPUsageService.shared.fetch(client: client, integration: integration)
            })
        }
        for id in ["ai-usage", "ai-limits"] {
            await usagePluginRegistry.register(LocalUsagePlugin(id: id, title: id, details: { snapshot, card in
                if id == "ai-usage" { return AnyView(AIUsagePluginDetail(snapshot: snapshot, configuration: card)) }
                return AnyView(AILimitsPluginDetail(configuration: card))
            }) { [weak self] configuration in
                guard let self else { throw UsagePluginError.invalidConfiguration }
                return await self.localUsageSnapshot(configuration)
            })
        }
    }

    func startUsagePlugins() async {
        if !ExtensionPluginAPI.v2Enabled { await registerBuiltInUsagePlugins() }
        do {
            if let saved = try await UsageDashboardStore.shared.load(at: activeWorkspace.storageURL) { usageDashboard = saved }
            else {
                let usage = UsageIntegration(pluginID: "ai-usage", title: "AI usage")
                let limits = UsageIntegration(pluginID: "ai-limits", title: "AI usage limits")
                usageDashboard = .init(integrations: [usage, limits], cards: [
                    .init(integrationID: usage.id, metricID: "top-model"),
                    .init(integrationID: usage.id, metricID: "time"),
                    .init(integrationID: usage.id, metricID: "tokens", showInWidget: true),
                    .init(integrationID: limits.id, style: "metrics", showInMenuBar: true, showInWidget: true)
                ])
            }
        } catch { usageDashboardError = "Could not load usage cards: \(error.localizedDescription)"; return }
        reconcileACPUsageIntegrations()
        if ExtensionPluginAPI.v2Enabled {
            await seedDashboardUsageExtensions()
            Task { try? await ExtensionCatalogController.shared.refresh() }
        }
        usagePluginRefreshTask?.cancel()
        usagePluginRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshUsagePlugins()
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
                if ExtensionPluginAPI.v2Enabled { try? await ExtensionCatalogController.shared.refresh() }
            }
        }
    }

    /// Only supported installed runtimes receive an automatic usage connection.
    func reconcileACPUsageIntegrations() {
        for client in acpClients where client.enabled {
            guard let provider = ACPUsageProvider.provider(for: client),
                  !usageDashboard.integrations.contains(where: { $0.pluginID == provider.pluginID && $0.resource == client.id }) else { continue }
            let integration = UsageIntegration(pluginID: provider.pluginID, title: "\(client.displayName) usage", resource: client.id)
            usageDashboard.integrations.append(integration)
            usageDashboard.cards.append(.init(integrationID: integration.id, style: "metrics"))
        }
    }

    /// Refreshes the usage integration for the active ACP client (used by chat footer & turn completion).
    func refreshACPUsage(for model: String?, clientID: String? = nil, forceRefresh: Bool = false) async {
        guard !usageDashboard.integrations.isEmpty else { return }
        reconcileACPUsageIntegrations()
        guard let resolvedID = resolvedACPUsageClientID(for: model, clientID: clientID),
              let client = acpClients.first(where: { $0.id == resolvedID && $0.enabled }),
              let provider = ACPUsageProvider.provider(for: client),
              let integration = usageDashboard.integrations.first(where: {
                  $0.resource == resolvedID && $0.pluginID == provider.pluginID
              }) else { return }

        if !forceRefresh,
           let existing = usageDashboard.snapshots.first(where: { $0.id == integration.id }),
           existing.error == nil,
           !existing.metrics.isEmpty,
           Date.now.timeIntervalSince(existing.fetchedAt) < 120 {
            return
        }

        await refreshUsageIntegration(integration)
        await persistUsageDashboard()
    }

    func refreshUsagePlugins() async {
        guard !usagePluginsRefreshing else { usagePluginsRefreshPending = true; return }
        usagePluginsRefreshing = true
        defer {
            usagePluginsRefreshing = false
            if usagePluginsRefreshPending {
                usagePluginsRefreshPending = false
                Task { await refreshUsagePlugins() }
            }
        }
        for integration in usageDashboard.integrations {
            await refreshUsageIntegration(integration)
        }
        await persistUsageDashboard()
    }

    func refreshUsageForExtension(_ id: String) async {
        let manifest = ExtensionCatalogController.shared.installed[id]?.manifest
        let plugins = Set(manifest?.contributes.usageProviders?.map(\.pluginID) ?? [])
        let affected = usageDashboard.integrations.filter { plugins.contains($0.pluginID) }
        guard !affected.isEmpty else { return }
        for integration in affected {
            if let old = usagePlugins.running.removeValue(forKey: integration.id) { old.task.cancel() }
            await refreshUsageIntegration(integration)
        }
        await persistUsageDashboard()
    }

    func markUsageExtension(_ id: String, manifest: ExtensionManifest?, status: UsageExtensionStatus) async {
        let plugins = Set(manifest?.contributes.usageProviders?.map(\.pluginID) ?? [])
        let affected = usageDashboard.integrations.filter {
            plugins.contains($0.pluginID) || BundledUsageExtensions.releaseID(for: $0.pluginID) == id
        }
        guard !affected.isEmpty else { return }
        for integration in affected {
            usagePlugins.running.removeValue(forKey: integration.id)?.task.cancel()
            usagePlugins.refreshingIntegrationIDs.remove(integration.id)
            usagePlugins.extensionStatuses[integration.id] = status
            let snapshot = refreshedUsageSnapshot(integration, error: status, status: status)
            usageDashboard.snapshots.removeAll { $0.id == integration.id }
            usageDashboard.snapshots.append(snapshot)
        }
        await persistUsageDashboard()
    }

    func updateUsageDashboard(_ dashboard: UsageDashboard) async -> Bool {
        do { try await UsageDashboardStore.shared.save(dashboard, at: activeWorkspace.storageURL) }
        catch { usageDashboardError = "Could not save usage cards: \(error.localizedDescription)"; return false }
        usageDashboard = dashboard
        publishUsageDashboard()
        return true
    }

    /// Every refresh entry point joins the same job. Only the current integration and generation
    /// can publish a result, including when a workspace changes during an XPC call.
    func refreshUsageIntegration(_ integration: UsageIntegration) async {
        let id = integration.id
        let root = activeWorkspace.storageURL
        guard usageDashboard.integrations.contains(integration) else { return }
        if let existing = usagePlugins.running[id] {
            if existing.integration == integration && existing.workspace == root {
                await existing.task.value
                return
            }
            existing.task.cancel()
        }
        let token = UUID()
        let job = Task { @MainActor in
            var generation: ActivatedExtension?
            var status: UsageExtensionStatus?
            let snapshot: UsagePluginSnapshot
            do {
                if ExtensionPluginAPI.v2Enabled {
                    let panel = try await prepareUsageExtension(integration)
                    generation = panel
                    guard let provider = panel.manifest.contributes.usageProviders?.first(where: { $0.pluginID == integration.pluginID }) else {
                        throw UsageExtensionStatus.unavailable
                    }
                    let plugin = ExtensionUsagePlugin(provider, appState: self)
                    await usagePluginRegistry.register(plugin)
                    snapshot = try await plugin.fetch(configuration: integration, credential: "", now: .now)
                } else {
                    snapshot = try await fetchBuiltInUsageSnapshot(integration)
                }
            } catch is CancellationError { return }
            catch {
                if ExtensionPluginAPI.v2Enabled {
                    status = UsageExtensionStatus.status(for: error) ?? (generation == nil ? .unavailable : nil)
                }
                snapshot = refreshedUsageSnapshot(integration, error: error, status: status)
            }
            guard !Task.isCancelled, activeWorkspace.storageURL == root, usagePlugins.running[id]?.id == token,
                  usageDashboard.integrations.contains(integration) else { return }
            if let generation, ExtensionCatalogController.shared.installedUsagePanel(
                pluginID: integration.pluginID, workspace: generation.workspace
            )?.broker !== generation.broker { return }
            usagePlugins.extensionStatuses[id] = status
            usageDashboard.snapshots.removeAll { $0.id == id }
            usageDashboard.snapshots.append(snapshot)
        }
        usagePlugins.running[id] = .init(id: token, integration: integration, workspace: root, task: job)
        usagePlugins.refreshingIntegrationIDs.insert(id)
        await job.value
        if usagePlugins.running[id]?.id == token {
            usagePlugins.running[id] = nil
            usagePlugins.refreshingIntegrationIDs.remove(id)
        }
    }

    /// A failed refresh retains both the metrics and their last successful observation time.
    private func refreshedUsageSnapshot(_ integration: UsageIntegration, error: Error, status: UsageExtensionStatus?) -> UsagePluginSnapshot {
        let message = status?.errorDescription ?? (error as? ACPUsageError)?.localizedDescription ??
            (error as? ACPUsageFetchError)?.localizedDescription ?? (error as? UsagePluginError)?.localizedDescription ??
            "Unable to refresh usage. Check the connection and credentials."
        return usageDashboard.failedSnapshot(for: integration, message: message)
    }

    private func fetchBuiltInUsageSnapshot(_ integration: UsageIntegration) async throws -> UsagePluginSnapshot {
        let registry = usagePluginRegistry
        if integration.pluginID.hasPrefix("ai-") || integration.pluginID.hasPrefix("acp-") {
            return try await registry.fetch(integration, credential: "")
        }
        // Billing uses its own API token and must not be blocked by an expired OAuth session.
        if integration.pluginID == "cloudflare", integration.resource.isEmpty,
           let billing = await UsageDashboardStore.shared.billingCredential(for: integration.id), !billing.isEmpty {
            return try await registry.fetch(integration, credential: billing)
        }
        let apiKey = await UsageDashboardStore.shared.credential(for: integration.id) ?? ""
        if integration.pluginID == "vercel" && !VercelUsageOAuth.isEnabled {
            return try await registry.fetch(integration, credential: apiKey)
        }
        return try await UsageOAuthTokens.shared.withAccessToken(integration) { token in
            try await registry.fetch(integration, credential: token ?? apiKey)
        }
    }

    func persistUsageDashboard() async {
        do { try await UsageDashboardStore.shared.save(usageDashboard, at: activeWorkspace.storageURL) }
        catch { usageDashboardError = "Could not save usage cards: \(error.localizedDescription)" }
        publishUsageDashboard()
    }

    func refreshLocalUsagePlugins() {
        if ExtensionPluginAPI.v2Enabled {
            usagePlugins.localRefreshPending = true
            guard usagePlugins.localRefreshTask == nil else { return }
            usagePlugins.localRefreshTask = Task {
                defer { usagePlugins.localRefreshTask = nil }
                while usagePlugins.localRefreshPending {
                    usagePlugins.localRefreshPending = false
                    for integration in usageDashboard.integrations where integration.pluginID.hasPrefix("ai-") {
                        await refreshUsageIntegration(integration)
                    }
                    await persistUsageDashboard()
                }
            }
            return
        }
        for integration in usageDashboard.integrations where integration.pluginID.hasPrefix("ai-") {
            usageDashboard.snapshots.removeAll { $0.id == integration.id }
            usageDashboard.snapshots.append(localUsageSnapshot(integration))
        }
        publishUsageDashboard()
    }

    func publishUsageDashboard() {
        guard desktopWidgetsActive else { return }
        scheduleMobileSnapshotBroadcast()
        scheduleDesktopWidgetUpdate()
        MobileSyncService.shared.pushWidgetUpdate()
    }

    private func localUsageSnapshot(_ integration: UsageIntegration) -> UsagePluginSnapshot {
        let ids: Set<UUID> = integration.projectID.map { [$0] } ?? []
        var metrics: [UsageMetric] = []
        if integration.pluginID == "ai-usage" {
            let summary = usageSummary(range: .week, projectIds: ids)
            metrics = [
                .init("tokens", "Tokens burned", value: Double(summary.totalTokens), unit: "tokens"),
                .init("time", "Session time", value: summary.sessionSeconds, unit: "seconds"),
                .init("turns", "Agent turns", value: Double(summary.turns), unit: "turns")
            ]
            metrics.insert(.init("top-model", "Most used model", value: summary.topModel.map { Double($0.turns) }, unit: "turns",
                detail: summary.topModel.map { usageModelDisplayName($0.model, provider: AgentProvider(rawValue: $0.providerRaw) ?? .acp) } ?? "No agent turns yet"), at: 0)
            metrics += summary.models.map {
                .init("model:\($0.id)", usageModelDisplayName($0.model, provider: AgentProvider(rawValue: $0.providerRaw) ?? .acp),
                      value: Double($0.turns), unit: "turns", detail: $0.providerRaw)
            }
        } else {
            for provider in Self.rateLimitedProviders {
                let usage = cachedRateLimitUsage(for: provider)
                let costs = rateLimitTaskCostSummary(for: provider, range: .week)
                metrics.append(.init("\(provider.rawValue):5h", "\(provider.displayNameText) · 5h", value: usage?.hasFiveHourLimit == true ? usage?.fiveHourPercent : nil, unit: "%"))
                metrics.append(.init("\(provider.rawValue):7d", "\(provider.displayNameText) · 7d", value: usage?.sevenDayPercent, unit: "%"))
                metrics.append(.init("\(provider.rawValue):cost", "\(provider.displayNameText) · Average task cost", value: costs.averageFiveHour, unit: "%", detail: "\(costs.sampleCount) samples · 5h window"))
                if case .tasks(let count) = costs.remainingFiveHour {
                    metrics.append(.init("\(provider.rawValue):remaining", "\(provider.displayNameText) · Estimated remaining", value: Double(count), unit: "tasks"))
                }
            }
        }
        return .init(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                     projectID: integration.projectID, scope: integration.projectID == nil ? "All projects" : "Project",
                     period: integration.pluginID == "ai-usage" ? "Last 7 days" : "Current limits · 7-day task samples",
                     fetchedAt: integration.pluginID == "ai-usage" ? .now : ([desktopClaudeUsageDate, desktopCodexUsageDate].compactMap { $0 }.min() ?? .distantPast), metrics: metrics)
    }
}
