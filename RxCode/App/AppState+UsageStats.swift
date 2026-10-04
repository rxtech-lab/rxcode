import Foundation
import RxCodeCore

/// Persists per-turn agent usage (model, session time, tokens) into the
/// pre-aggregated `UsageStatBucket` rows read by the briefing statistics panel.
extension AppState {
    /// Folds one `result` event into the usage buckets.
    ///
    /// - Parameters:
    ///   - since: When the measured span started (stream start, or the previous
    ///     result on the same stream). Session time is wall-clock so every
    ///     provider is measured the same way, including ACP which reports no
    ///     `durationMs`.
    func recordUsageStats(
        resultEvent: ResultEvent,
        since: Date,
        agentProvider: AgentProvider,
        model: String?,
        projectId: UUID,
        now: Date = .now
    ) {
        let usage = resultEvent.usage
        let sample = UsageStatSample(
            projectId: projectId,
            providerRaw: agentProvider.rawValue,
            model: model,
            sessionSeconds: now.timeIntervalSince(since),
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            cacheCreationTokens: usage?.cacheCreationInputTokens ?? 0,
            cacheReadTokens: usage?.cacheReadInputTokens ?? 0
        )
        threadStore.recordUsage(sample, at: now)
        usageStatsRevision += 1
    }

    /// Aggregated usage for the briefing statistics panel.
    func usageSummary(range: UsageStatsRange, projectIds: Set<UUID>) -> UsageStatsSummary {
        threadStore.usageSummary(range: range, projectIds: projectIds)
    }

    /// Display label for a model recorded in the usage buckets. Claude Code
    /// records the full model id reported by the CLI (e.g. `claude-opus-5-5`).
    func usageModelDisplayName(_ model: String, provider: AgentProvider) -> String {
        if model.isEmpty { return "Default" }
        if provider == .claudeCode, model.hasPrefix("claude-") {
            return Self.formatModelId(model)
        }
        return modelDisplayLabel(model, provider: provider)
    }
}
