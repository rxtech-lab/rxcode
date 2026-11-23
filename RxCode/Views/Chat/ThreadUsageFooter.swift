import RxCodeCore
import SwiftUI

/// Compact chip in the composer row summarizing how much of each provider's
/// rate limits this thread has consumed. Clicking it opens a breakdown popover.
struct ThreadUsageChip: View {
    @Environment(AppState.self) private var appState
    let threadID: String
    /// Provider whose numbers the chip shows when the thread used several.
    let preferredProvider: AgentProvider

    @State private var usage: [ThreadRateLimitUsage] = []
    @State private var isPresented = false
    @State private var isHovered = false

    private var primary: ThreadRateLimitUsage? {
        usage.first { $0.provider == preferredProvider } ?? usage.first
    }

    var body: some View {
        Button { isPresented.toggle() } label: { label }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("thread-usage-footer")
            .help("Rate-limit usage for this thread")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ThreadUsagePopover(usage: usage)
            }
            .task(id: "\(threadID):\(appState.rateLimitHistoryRevision)") {
                let totals = await appState.threadStoreReader.loadThreadRateLimitUsage(threadId: threadID)
                guard !Task.isCancelled else { return }
                usage = totals
            }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            HStack(spacing: 4) {
                if hasFiveHourLimit(primary?.provider ?? preferredProvider, in: appState) {
                    windowValue("5h", primary?.fiveHour)
                    Text(verbatim: "·").foregroundStyle(ClaudeTheme.textTertiary)
                }
                windowValue("7d", primary?.sevenDay)
            }
            if usage.count > 1 {
                Text(verbatim: "+\(usage.count - 1)")
                    .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(ClaudeTheme.surfaceTertiary, in: Capsule())
            }
        }
        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
        .monospacedDigit()
        .foregroundStyle(isHovered || isPresented ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            (isHovered || isPresented) ? ClaudeTheme.surfaceSecondary.opacity(0.85) : Color.clear,
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func windowValue(_ name: String, _ window: ThreadRateLimitUsage.Window?) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: name).foregroundStyle(ClaudeTheme.textTertiary)
            Text(verbatim: ThreadUsagePopover.formatted(window?.percent))
            if window?.isPartial == true {
                Text(verbatim: "*").foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
    }
}

/// Per-provider breakdown of the limits a thread consumed.
struct ThreadUsagePopover: View {
    @Environment(AppState.self) private var appState
    let usage: [ThreadRateLimitUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thread Usage")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text("Share of each provider’s limits used by this thread")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }

            if usage.isEmpty {
                Text("No measured turns yet")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(usage, id: \.provider) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.provider.displayNameText)
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        if hasFiveHourLimit(row.provider, in: appState) {
                            meter(String(localized: "5-hour limit"), row.fiveHour)
                        }
                        meter(String(localized: "Weekly limit"), row.sevenDay)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                }
            }

            Text("Estimated from changes in provider limits across this thread’s turns. Partial totals (*) exclude turns that overlapped other runs or crossed a reset.")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func meter(_ title: String, _ window: ThreadRateLimitUsage.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                if window.isPartial {
                    Text("Partial")
                        .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ClaudeTheme.accent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                Text(verbatim: Self.formatted(window.percent))
                    .monospacedDigit()
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            ProgressView(value: min(max(window.percent ?? 0, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(ClaudeTheme.accent)
                .controlSize(.small)
        }
    }

    static func formatted(_ percent: Double?) -> String {
        percent.map(BriefingRateLimitStatsView.formatDelta) ?? "—"
    }
}
