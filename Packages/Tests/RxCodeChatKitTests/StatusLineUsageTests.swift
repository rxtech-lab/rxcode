import RxCodeCore
import SwiftUI
import Testing
import ViewInspector
@testable import RxCodeChatKit

@MainActor
struct StatusLineUsageTests {
    @Test func standaloneChatCanPopulateUsageWithItsFetchHandler() async {
        let bridge = ChatBridge()
        let usage = RateLimitUsage(fiveHourPercent: 8, sevenDayPercent: 16,
                                   fiveHourResetsAt: nil, sevenDayResetsAt: nil)
        bridge.fetchRateLimitHandler = { provider in provider == .claudeCode ? usage : nil }
        _ = await bridge.fetchRateLimit()
        #expect(bridge.rateLimitUsage == usage)
        bridge.agentProvider = .codex
        #expect(bridge.rateLimitUsage == nil)
    }

    @Test func footerPicksUpAnAccountReadingAfterItsInitialFetchMisses() async throws {
        let limits = AccountRateLimits()
        let bridge = ChatBridge()
        bridge.accountRateLimits = limits
        bridge.fetchRateLimitHandler = { _ in nil }
        let footer = StatusLineView().environment(bridge)
        func labels() throws -> [String] {
            try footer.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        }

        let initial = await bridge.fetchRateLimit()
        #expect(initial == nil)
        #expect(try labels().contains("--"))

        let usage = RateLimitUsage(fiveHourPercent: 0.4, sevenDayPercent: 22.7,
                                   fiveHourResetsAt: nil, sevenDayResetsAt: nil)
        await confirmation("The footer observes a reading published by another usage surface") { changed in
            withObservationTracking {
                _ = bridge.rateLimitUsage
            } onChange: { changed() }
            _ = await limits.refresh(for: .claudeCode) { usage }
        }
        #expect(try labels().contains(RateLimitUsage.formattedPercent(0.4)))
        #expect(try labels().contains(RateLimitUsage.formattedPercent(23)))

        let measuredAt = limits[.claudeCode]?.measuredAt
        _ = await limits.refresh(for: .claudeCode) { nil }
        #expect(limits[.claudeCode]?.measuredAt == measuredAt)
        #expect(try labels().contains(RateLimitUsage.formattedPercent(23)))
    }

    @Test func switchingProvidersReadsOnlyTheSelectedAccountsWindows() async throws {
        let limits = AccountRateLimits()
        let bridge = ChatBridge()
        bridge.accountRateLimits = limits
        let footer = StatusLineView().environment(bridge)
        let reset = Date.now.addingTimeInterval(86_400)
        let codex = RateLimitUsage(fiveHourPercent: 42, sevenDayPercent: 42,
                                   fiveHourResetsAt: reset, sevenDayResetsAt: reset)
        _ = await limits.refresh(for: .codex) { codex }
        bridge.agentProvider = .codex

        let claude = RateLimitUsage(fiveHourPercent: 7, sevenDayPercent: 15,
                                    fiveHourResetsAt: nil, sevenDayResetsAt: nil)
        _ = await limits.refresh(for: .claudeCode) { claude }
        let labels = try footer.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.filter { $0 == RateLimitUsage.formattedPercent(42) }.count == 1)
        #expect(!labels.contains(RateLimitUsage.formattedPercent(7)))

        bridge.agentProvider = .claudeCode
        #expect(try footer.inspect().find(text: RateLimitUsage.formattedPercent(7)).string()
                == RateLimitUsage.formattedPercent(7))
    }
}
