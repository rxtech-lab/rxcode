import Foundation
import RxCodeCore

extension AppState {
    func resolvedACPUsageClientID(for model: String?, clientID: String? = nil) -> String? {
        if let clientID, !clientID.isEmpty { return clientID }
        if let selected = acpSelectionParts(for: model)?.clientId, !selected.isEmpty { return selected }
        if !selectedACPClientId.isEmpty { return selectedACPClientId }
        return acpClients.first(where: \.enabled)?.id
    }

    func supportsACPUsage(for model: String?, clientID: String? = nil) -> Bool {
        guard let resolvedID = resolvedACPUsageClientID(for: model, clientID: clientID),
              let client = acpClients.first(where: { $0.id == resolvedID && $0.enabled }) else {
            return false
        }
        return ACPUsageProvider.provider(for: client) != nil
    }

    func acpUsageSnapshot(for model: String?, clientID: String? = nil) -> UsagePluginSnapshot? {
        guard let resolvedClientID = resolvedACPUsageClientID(for: model, clientID: clientID),
              let client = acpClients.first(where: { $0.id == resolvedClientID }),
              let provider = ACPUsageProvider.provider(for: client),
              let integration = usageDashboard.integrations.first(where: {
                  $0.resource == resolvedClientID && $0.pluginID == provider.pluginID
              }) else { return nil }
        return usageDashboard.snapshots.first { $0.id == integration.id && $0.pluginID == integration.pluginID }
    }

    /// Reads the same cached data used by usage cards. Recording never triggers
    /// an extra provider request or treats an account quota as a model quota.
    func codingAnalyticsLimits(
        provider: AgentProvider, model: String?, clientID: String? = nil,
        phase: CodingUsageLimitSnapshot.Phase, now: Date = .now
    ) -> CodingUsageLimitSnapshot {
        if provider != .acp {
            let limits = cachedRateLimitUsage(for: provider)
            let measuredAt = provider == .claudeCode ? desktopClaudeUsageDate : desktopCodexUsageDate
            let stale = measuredAt.map { now.timeIntervalSince($0) > 3600 } ?? true
            return .init(phase: phase, provider: provider.rawValue, model: model,
                         status: limits == nil ? .unavailable : (stale ? .stale : .available),
                         scope: "provider_account", source: "cached_provider_limits", measuredAt: measuredAt,
                         rateLimits: limits, reason: limits == nil ? "No cached provider usage limits." : nil, capturedAt: now)
        }
        let selection = acpSelectionParts(for: model)
        let resolvedClientID = resolvedACPUsageClientID(for: model, clientID: clientID ?? selection?.clientId)
        let selectedModel = selection?.model ?? model
        let client = resolvedClientID.flatMap { id in acpClients.first { $0.id == id } }
        let usageProvider = client.flatMap { ACPUsageProvider.provider(for: $0) }
        let snapshot = acpUsageSnapshot(for: model, clientID: resolvedClientID)
        let hasValues = snapshot?.metrics.contains { $0.value != nil } == true
        return .init(phase: phase, provider: provider.rawValue, acpClientID: resolvedClientID, model: selectedModel,
                     status: usageProvider == nil ? .unsupported : (!hasValues ? .unavailable : (snapshot?.isStale(at: now) == true ? .stale : .available)),
                     scope: "provider_reported_buckets", source: usageProvider?.pluginID ?? "acp",
                     measuredAt: snapshot?.fetchedAt, metrics: snapshot?.metrics ?? [],
                     reason: usageProvider == nil ? "This ACP client does not expose usage limits."
                        : (!hasValues ? "No cached ACP usage limits." : (snapshot?.error != nil ? "Provider usage refresh failed." : nil)),
                     capturedAt: now)
    }
}
