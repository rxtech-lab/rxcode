import RxCodeChatKit
import RxCodeCore
import SwiftUI
import XCTest
@testable import RxCode

extension AppStateTests {
    func testChatFooterSharesMenuBarUsageAcrossWorkspaces() async {
        let workspace = AppWorkspace(id: UUID().uuidString, name: "Second workspace", createdAt: .now, updatedAt: .now)
        let other = AppState(core: appState.core, workspace: workspace, persistence: persistence, startBackgroundServices: false)
        let bridge = ChatBridge()
        window.sessionAgentProvider = .claudeCode
        appState.setupChatBridge(bridge, for: window)
        XCTAssertNil(bridge.rateLimitUsage)

        let usage = RateLimitUsage(fiveHourPercent: 18, sevenDayPercent: 31,
                                   fiveHourResetsAt: nil, sevenDayResetsAt: nil)
        _ = await other.core.accountRateLimits.refresh(for: .claudeCode) { usage }
        XCTAssertEqual(bridge.rateLimitUsage, usage)
        XCTAssertEqual(other.cachedRateLimitUsage(for: .claudeCode), bridge.rateLimitUsage)

        // The Claude service returns no live reading in unit tests.
        let afterFailedRefresh = await other.rateLimitUsage(for: .claudeCode, forceRefresh: true)
        XCTAssertEqual(afterFailedRefresh, usage)
        XCTAssertEqual(appState.latestRateLimitUsage, bridge.rateLimitUsage)
        XCTAssertNil(other.cachedRateLimitUsage(for: .codex))
    }

    func testThreadUsageHidesMirroredFiveHourLimitsPerProvider() async throws {
        let threadID = UUID().uuidString
        let reset = Date.now
        for provider in [AgentProvider.codex, .claudeCode] {
            appState.threadStore.recordRateLimitTaskCost(RateLimitTaskCost(
                providerRaw: provider.rawValue, model: nil, projectId: nil, threadId: threadID, threadTitle: "",
                startedAt: reset, endedAt: reset, fiveHourDelta: nil, sevenDayDelta: 1, concurrentRuns: 0
            ))
        }
        let accounts = appState.core.accountRateLimits
        _ = await accounts.refresh(for: .claudeCode) {
            RateLimitUsage(fiveHourPercent: 42, sevenDayPercent: 42,
                           fiveHourResetsAt: reset, sevenDayResetsAt: reset.addingTimeInterval(86_400))
        }
        let usage = await appState.threadStoreReader.loadThreadRateLimitUsage(threadId: threadID)
        let host = NSHostingView(rootView: VStack {
            ThreadUsageChip(threadID: threadID, preferredProvider: .codex)
            ThreadUsagePopover(usage: usage)
        }.environment(appState))
        let panel = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 480),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.orderBack(nil)
        defer { panel.orderOut(nil) }

        // SwiftUI creates the accessibility tree when the app first receives an accessibility query.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        func elements() -> [AnyObject] {
            host.layoutSubtreeIfNeeded()
            return (host.accessibilityChildren() ?? []).map { $0 as AnyObject }
        }
        func checkChip(showsFiveHour: Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            var label = ""
            repeat {
                let button = elements().first { $0.accessibilityIdentifier?() == "thread-usage-footer" }
                label = button?.accessibilityLabel?() ?? ""
                if label.contains(BriefingRateLimitStatsView.formatDelta(1)), label.contains("5h") == showsFiveHour { break }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            XCTAssertTrue(label.contains("7d") && label.contains(BriefingRateLimitStatsView.formatDelta(1)), label)
            XCTAssertEqual(label.contains("5h"), showsFiveHour, label)
            if !showsFiveHour {
                XCTAssertFalse(label.contains("·") || label.contains("*"), label)
            }
        }
        try await checkChip(showsFiveHour: true)
        _ = await accounts.refresh(for: .codex) {
            RateLimitUsage(fiveHourPercent: 42, sevenDayPercent: 42,
                           fiveHourResetsAt: reset, sevenDayResetsAt: reset)
        }
        try await checkChip(showsFiveHour: false)

        let labels = elements().compactMap { node -> String? in
            guard node.accessibilityRole?() == .staticText else { return nil }
            return node.accessibilityValue?()
        }
        let weekly = String(localized: "Weekly limit")
        let expected = [AgentProvider.claudeCode.displayNameText, String(localized: "5-hour limit"),
                        String(localized: "Partial"), weekly, AgentProvider.codex.displayNameText, weekly]
        XCTAssertEqual(labels.filter { expected.contains($0) }, expected)
    }
}
