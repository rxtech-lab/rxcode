import RxCodeCore
import SwiftUI

struct ThreadUsageFooter: View {
    @Environment(AppState.self) private var appState
    let threadID: String
    @State private var usage: [ThreadRateLimitUsage] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Thread usage")
                .fontWeight(.medium)
            VStack(alignment: .leading, spacing: 3) {
                if usage.isEmpty {
                    Text("5h — · 7d —")
                }
                ForEach(usage, id: \.provider) { row in
                    Text("\(row.provider.displayNameText) · 5h \(formatted(row.fiveHour)) · 7d \(formatted(row.sevenDay))")
                }
            }
            .monospacedDigit()
        }
        .font(.system(size: ClaudeTheme.messageSize(11)))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread-usage-footer")
        .help("Estimated from changes in provider limits across this thread’s recorded turns. Partial totals exclude readings marked as overlapping or reset. A dash means no measurement is available.")
        .task(id: appState.rateLimitHistoryRevision) {
            let totals = await appState.threadStoreReader.loadThreadRateLimitUsage(threadId: threadID)
            guard !Task.isCancelled else { return }
            usage = totals
        }
    }

    private func formatted(_ window: ThreadRateLimitUsage.Window) -> String {
        guard let percent = window.percent else { return "—" }
        let value = BriefingRateLimitStatsView.formatDelta(percent)
        return window.isPartial ? String(localized: "\(value) (partial)") : value
    }
}
