import Foundation
import RxCodeCore

/// Usage-limit history and per-task limit cost tracking for Claude Code and
/// Codex, read by the briefing page's usage-limit statistics.
extension AppState {
    /// How often limits are polled in the background so the history chart has
    /// points even while the user isn't looking at a usage surface.
    static let rateLimitSamplingInterval: UInt64 = 10 * 60 * 1_000_000_000
    /// Wait after a task finishes before reading limits again, so the
    /// provider's usage counters have caught up with the task's last requests.
    static let rateLimitSettleDelay: UInt64 = 5 * 1_000_000_000

    /// Providers that report 5-hour / 7-day usage limits.
    static let rateLimitedProviders: [AgentProvider] = [.claudeCode, .codex]

    /// In-flight cost measurement for one agent stream.
    struct RateLimitMeasurement {
        let provider: AgentProvider
        /// Limit reading taken before the span being measured.
        var baseline: Task<RateLimitUsage?, Never>
        /// Most other runs on the same provider seen during the span.
        var concurrentRuns: Int
    }

    /// Persists a fresh limit reading into the history chart's samples.
    func recordRateLimitSample(_ usage: RateLimitUsage, for provider: AgentProvider) {
        guard Self.rateLimitedProviders.contains(provider) else { return }
        if threadStore.recordRateLimitSample(usage, providerRaw: provider.rawValue) {
            rateLimitHistoryRevision += 1
        }
        refreshRateLimitProviderStats()
    }

    /// Starts the background poll that keeps the usage-limit history filled.
    func startRateLimitSampling() {
        guard rateLimitSamplingTask == nil else { return }
        refreshRateLimitProviderStats()
        rateLimitSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppState.rateLimitSamplingInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshRateLimitUsage(forceRefresh: true)
                await self?.refreshCodexRateLimitUsage(forceRefresh: true)
            }
        }
    }

    // MARK: - Per-task cost

    /// Takes the "before" limit reading for a stream. Returns nil for
    /// providers without usage limits. Pair with `endRateLimitMeasurement`.
    func beginRateLimitMeasurement(for provider: AgentProvider) -> RateLimitMeasurement? {
        guard !AppSupport.isTestProcess, Self.rateLimitedProviders.contains(provider) else { return nil }
        if provider == .codex, !codexInstalled { return nil }
        let active = (activeRateLimitRuns[provider] ?? 0) + 1
        activeRateLimitRuns[provider] = active
        let baseline = Task<RateLimitUsage?, Never> { [weak self] in
            await self?.rateLimitUsage(for: provider, forceRefresh: true)
        }
        return RateLimitMeasurement(provider: provider, baseline: baseline, concurrentRuns: active - 1)
    }

    func endRateLimitMeasurement(_ measurement: RateLimitMeasurement?) {
        guard let provider = measurement?.provider else { return }
        activeRateLimitRuns[provider] = max(0, (activeRateLimitRuns[provider] ?? 0) - 1)
    }

    /// Records the limit cost of the span that just ended with a `result`, and
    /// makes the "after" reading the baseline for the next span on the stream.
    func recordRateLimitTaskCost(
        _ measurement: inout RateLimitMeasurement?,
        model: String?,
        projectId: UUID,
        threadId: String,
        prompt: String,
        tokens: Int,
        startedAt: Date,
        endedAt: Date = .now
    ) {
        guard var current = measurement else { return }
        let provider = current.provider
        let othersNow = max(0, (activeRateLimitRuns[provider] ?? 1) - 1)
        let concurrentRuns = max(current.concurrentRuns, othersNow)
        let baseline = current.baseline
        let fallbackTitle = Self.rateLimitTaskTitle(fromPrompt: prompt)

        let after = Task<RateLimitUsage?, Never> { [weak self] in
            let before = await baseline.value
            try? await Task.sleep(nanoseconds: AppState.rateLimitSettleDelay)
            guard let self else { return nil }
            let after = await self.rateLimitUsage(for: provider, forceRefresh: true)
            guard let before, let after else { return after }
            let delta = RateLimitDelta.between(before, after)
            let storedTitle = self.threadStore.fetch(id: threadId)?.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = storedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
            self.threadStore.recordRateLimitTaskCost(RateLimitTaskCost(
                providerRaw: provider.rawValue,
                model: model,
                projectId: projectId,
                threadId: threadId,
                threadTitle: title,
                startedAt: startedAt,
                endedAt: endedAt,
                fiveHourDelta: delta.fiveHour,
                sevenDayDelta: delta.sevenDay,
                concurrentRuns: concurrentRuns,
                tokens: tokens
            ))
            self.rateLimitHistoryRevision += 1
            self.refreshRateLimitProviderStats()
            return after
        }

        current.baseline = after
        current.concurrentRuns = othersNow
        measurement = current
    }

    /// Uncached tokens a `result` accounts for; cache reads barely count
    /// toward usage limits, so they're left out.
    static func rateLimitTaskTokens(_ usage: UsageInfo?) -> Int {
        guard let usage else { return 0 }
        return usage.inputTokens + usage.outputTokens + usage.cacheCreationInputTokens
    }

    /// First line of the prompt, shortened, for tasks whose thread has no title.
    static func rateLimitTaskTitle(fromPrompt prompt: String) -> String {
        let line = prompt
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return "Untitled task" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    // MARK: - Per-model estimates and advice

    /// Window of task costs behind the per-model estimates and advice.
    static let rateLimitAdviceRange: UsageStatsRange = .week

    /// Recomputes `rateLimitProviderStats` off the main actor from the stored
    /// task costs and the latest limits. Called whenever either changes.
    func refreshRateLimitProviderStats() {
        let since = Self.rateLimitAdviceRange.cutoff(now: .now)
        let inputs = Self.rateLimitedProviders.map { provider in
            (
                provider: provider,
                costs: threadStore.rateLimitTaskCosts(providerRaw: provider.rawValue, since: since),
                usage: cachedRateLimitUsage(for: provider)
            )
        }
        rateLimitProviderStatsTask?.cancel()
        rateLimitProviderStatsTask = Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                var result: [AgentProvider: RateLimitTaskCostSummary] = [:]
                for input in inputs {
                    result[input.provider] = RateLimitTaskCostSummary.aggregate(input.costs, current: input.usage)
                }
                return result
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.rateLimitProviderStats != stats {
                self.rateLimitProviderStats = stats
            }
        }
    }

    /// Advice for running `model` on `provider` next, from the background
    /// stats; nil when its limits need no attention.
    func rateLimitAdvice(for provider: AgentProvider, model: String?) -> RateLimitAdvice? {
        guard Self.rateLimitedProviders.contains(provider) else { return nil }
        let contexts = Self.rateLimitedProviders
            .filter { $0 != .codex || codexInstalled }
            .map { candidate in
                RateLimitAdvisor.ProviderContext(
                    providerRaw: candidate.rawValue,
                    displayName: candidate.displayNameText,
                    usage: cachedRateLimitUsage(for: candidate),
                    summary: rateLimitProviderStats[candidate] ?? RateLimitTaskCostSummary()
                )
            }
        guard let context = contexts.first(where: { $0.providerRaw == provider.rawValue }) else { return nil }
        return RateLimitAdvisor.advise(
            context: context,
            model: model,
            alternatives: contexts,
            modelDisplayName: { [weak self] id in
                self?.usageModelDisplayName(id, provider: provider) ?? id
            }
        )
    }

    // MARK: - Reads

    func rateLimitSamples(for provider: AgentProvider, range: UsageStatsRange, now: Date = .now) -> [RateLimitSamplePoint] {
        threadStore.rateLimitSamples(providerRaw: provider.rawValue, since: range.cutoff(now: now))
    }

    /// Limit used per million tokens for each of the last `weeks` calendar
    /// weeks, oldest first. Independent of the briefing window so the trend
    /// always spans several weeks.
    func rateLimitWeeklyCosts(for provider: AgentProvider, weeks: Int = 12, now: Date = .now) -> [RateLimitWeeklyCost] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let since = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        return RateLimitWeeklyCost.weekly(
            threadStore.rateLimitTaskCosts(providerRaw: provider.rawValue, since: since),
            calendar: calendar
        )
    }

    func rateLimitTaskCostSummary(
        for provider: AgentProvider,
        range: UsageStatsRange,
        now: Date = .now
    ) -> RateLimitTaskCostSummary {
        RateLimitTaskCostSummary.aggregate(
            threadStore.rateLimitTaskCosts(providerRaw: provider.rawValue, since: range.cutoff(now: now)),
            current: cachedRateLimitUsage(for: provider)
        )
    }
}
