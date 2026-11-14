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
        case .acp, .localAgent:
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
            case .acp, .localAgent:
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
            desktopClaudeUsageDate = .now
        case .codex:
            latestCodexRateLimitUsage = usage
            desktopCodexUsageDate = .now
        case .acp, .localAgent:
            break
        }
        recordRateLimitSample(usage, for: provider)
        refreshLocalUsagePlugins()
        scheduleDesktopWidgetUpdate()
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
            await refreshACPUsage(for: selectedModel, clientID: selectedACPClientId, forceRefresh: forceRefresh)
        case .localAgent:
            break
        }
    }
}


extension AppState {
    /// Only terminal quota failures arm a retry; transient provider retries remain provider-owned.
    func scheduleUsageLimitResume(error: String, sessionKey: String, provider: AgentProvider, projectId: UUID) {
        guard provider == .claudeCode || provider == .codex else { return }
        let text = error.lowercased()
        guard ["usage limit", "usage_limit", "hit your limit", "rate limit", "rate_limit"].contains(where: text.contains) else { return }
        usageLimitResumeTasks[sessionKey]?.cancel()
        usageLimitResumeTasks[sessionKey] = Task { [weak self] in
            guard let self else { return }
            var dispatched = false
            defer {
                if !dispatched && !Task.isCancelled { self.usageLimitResumeTasks[sessionKey] = nil }
            }
            let usage = await self.rateLimitUsage(for: provider, forceRefresh: true)
            guard !Task.isCancelled, let usage else { return }
            let windows: [(Double, Date?)] = [
                (usage.fiveHourPercent, usage.fiveHourResetsAt),
                (usage.sevenDayPercent, usage.sevenDayResetsAt),
                (usage.twentyFourHourPercent ?? 0, usage.twentyFourHourResetsAt)
            ]
            let exhausted = windows.filter { $0.0 >= 100 }
            guard !exhausted.isEmpty, exhausted.allSatisfy({ $0.1 != nil }),
                  let reset = exhausted.compactMap({ $0.1 }).max(), reset > Date() else { return }
            self.updateState(sessionKey) { state in
                state.messages.append(ChatMessage(role: .assistant, content: "Usage limit reached. Automatic resume scheduled for \(reset.formatted()). You can switch threads; sending a message or stopping this thread cancels the pending resume."))
            }
            await self.saveSession(sessionId: sessionKey, projectId: projectId, messages: self.stateForSession(sessionKey).messages)
            do {
                while Date() < reset.addingTimeInterval(5) {
                    try await Task.sleep(for: .seconds(min(30, reset.addingTimeInterval(5).timeIntervalSinceNow)))
                }
            } catch { return }
            guard !Task.isCancelled,
                  self.sessionStates[sessionKey]?.agentProvider == provider,
                  self.sessionStates[sessionKey]?.isStreaming == false else { return }
            self.usageLimitResumeTasks[sessionKey] = nil
            dispatched = true
            do {
                _ = try await self.sendCrossProject(
                    projectId: projectId,
                    threadId: sessionKey,
                    prompt: "Continue from where you stopped before the usage limit was reached.",
                    waitForResponse: false
                )
            } catch {
                self.updateState(sessionKey) { state in
                    state.messages.append(ChatMessage(role: .assistant, content: "Automatic resume failed: \(error.localizedDescription)", isError: true))
                }
                await self.saveSession(sessionId: sessionKey, projectId: projectId, messages: self.stateForSession(sessionKey).messages)
            }
        }
    }
}
