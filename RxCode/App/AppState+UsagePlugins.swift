import Foundation
import RxCodeCore

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

    static let usagePluginIDs = ["ai-usage", "ai-limits", "vercel", "neon", "turso", "cloudflare", "github-ci"]

    func startUsagePlugins() async {
        for id in ["vercel", "neon", "turso", "cloudflare"] {
            await usagePluginRegistry.register(CloudUsagePlugin(id: id))
        }
        await usagePluginRegistry.register(GitHubCIUsagePlugin())
        for id in ["ai-usage", "ai-limits"] {
            await usagePluginRegistry.register(LocalUsagePlugin(id: id, title: id) { [weak self] configuration in
                guard let self else { throw UsagePluginError.invalidConfiguration }
                return await self.localUsageSnapshot(configuration)
            })
        }
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
        usagePluginRefreshTask?.cancel()
        usagePluginRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshUsagePlugins()
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
            }
        }
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
            let snapshot: UsagePluginSnapshot
            do {
                var token = ""
                if !integration.pluginID.hasPrefix("ai-") {
                    let oauthToken = try await UsageOAuthTokens.shared.accessToken(integration)
                    let apiKey = await UsageDashboardStore.shared.credential(for: integration.id)
                    token = oauthToken ?? apiKey ?? ""
                }
                snapshot = try await usagePluginRegistry.fetch(integration, credential: token)
            } catch {
                var previous = usageDashboard.snapshots.first { $0.id == integration.id }
                    ?? .init(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                             projectID: integration.projectID, scope: integration.account, period: "", metrics: [])
                previous.error = (error as? UsagePluginError)?.localizedDescription ?? "Unable to refresh usage. Check the connection and credentials."
                snapshot = previous
            }
            // A deleted or edited integration must not be resurrected by an in-flight fetch.
            guard usageDashboard.integrations.contains(integration) else { continue }
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

    func persistUsageDashboard() async {
        do { try await UsageDashboardStore.shared.save(usageDashboard, at: activeWorkspace.storageURL) }
        catch { usageDashboardError = "Could not save usage cards: \(error.localizedDescription)" }
        publishUsageDashboard()
    }

    func refreshLocalUsagePlugins() {
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
