import Foundation
import RxCodeCore

extension AppState {
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
        let resolvedClientID = clientID ?? selection?.clientId ?? selectedACPClientId
        let selectedModel = selection?.model ?? model
        let client = acpClients.first { $0.id == resolvedClientID }
        let usageProvider = client.flatMap { ACPUsageProvider.provider(for: $0) }
        let integration = usageDashboard.integrations.first {
            $0.resource == resolvedClientID && $0.pluginID == usageProvider?.pluginID
        }
        let snapshot = integration.flatMap { integration in
            usageDashboard.snapshots.first { $0.id == integration.id && $0.pluginID == integration.pluginID }
        }
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
