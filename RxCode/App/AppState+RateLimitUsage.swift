import Foundation
import RxCodeChatKit
import RxCodeCore

// MARK: - Rate-Limit Usage

extension AppState {
    func cachedRateLimitUsage(for provider: AgentProvider) -> RateLimitUsage? {
        switch provider {
        case .claudeCode:
            return latestRateLimitUsage
        case .codex:
            return latestCodexRateLimitUsage
        case .acp:
            return nil
        }
    }

    func rateLimitUsage(for provider: AgentProvider, forceRefresh: Bool = false) async -> RateLimitUsage? {
        if !forceRefresh, let cached = cachedRateLimitUsage(for: provider) {
            return cached
        }

        if let task = rateLimitUsageRefreshTasks[provider] {
            return await task.value ?? cachedRateLimitUsage(for: provider)
        }

        let task = Task<RateLimitUsage?, Never> { [weak self] in
            guard let self else { return nil }
            switch provider {
            case .claudeCode:
                return await RateLimitService.shared.fetchUsage(forceRefresh: forceRefresh)
            case .codex:
                guard self.codexInstalled else { return nil }
                return await self.codex.fetchRateLimits(forceRefresh: forceRefresh)
            case .acp:
                return nil
            }
        }
        rateLimitUsageRefreshTasks[provider] = task

        let usage = await task.value
        rateLimitUsageRefreshTasks[provider] = nil

        if let usage {
            storeRateLimitUsage(usage, for: provider)
            return usage
        }
        return cachedRateLimitUsage(for: provider)
    }

    func storeRateLimitUsage(_ usage: RateLimitUsage, for provider: AgentProvider) {
        switch provider {
        case .claudeCode:
            latestRateLimitUsage = usage
        case .codex:
            latestCodexRateLimitUsage = usage
        case .acp:
            break
        }
        // Refresh the mobile home-screen widget's usage figures.
        MobileSyncService.shared.pushWidgetUpdate()
    }

    /// Force-refresh the shared Claude rate-limit usage.
    func refreshRateLimitUsage(forceRefresh: Bool = false) async {
        _ = await rateLimitUsage(for: .claudeCode, forceRefresh: forceRefresh)
    }

    /// Warm Codex usage early so the status bar can render Codex limits from cache.
    func refreshCodexRateLimitUsage(forceRefresh: Bool = false) async {
        _ = await rateLimitUsage(for: .codex, forceRefresh: forceRefresh)
    }

    func refreshSelectedAgentRateLimitUsage(forceRefresh: Bool = false) async {
        switch selectedAgentProvider {
        case .claudeCode:
            await refreshRateLimitUsage(forceRefresh: forceRefresh)
        case .codex:
            await refreshCodexRateLimitUsage(forceRefresh: forceRefresh)
        case .acp:
            break
        }
    }
}
