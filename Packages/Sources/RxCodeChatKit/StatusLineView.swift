import SwiftUI
import RxCodeCore

struct StatusLineView: View {
    @Environment(ChatBridge.self) private var chatBridge
    @State private var rateLimit: RateLimitUsage?
    @State private var showFiveHourPopover = false
    @State private var showSevenDayPopover = false
    @State private var showContextPopover = false

    private var totalResponseDuration: Double {
        chatBridge.messages
            .filter { $0.role == .assistant }
            .compactMap { $0.duration }
            .reduce(0, +)
    }

    private var contextPercentage: Double? {
        guard let pct = chatBridge.lastTurnContextUsedPercentage else { return nil }
        return min(pct, 100)
    }

    var body: some View {
        HStack(spacing: 10) {
            providerMenuSegment()

            Divider().frame(height: 12)

            usageSegments()

            Divider().frame(height: 12)

            contextSegment()

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "stopwatch")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text(formatTotalDuration(totalResponseDuration))
            }
            .foregroundStyle(ClaudeTheme.textTertiary)

            Divider().frame(height: 12)

            versionSegment()
        }
        .font(.system(size: ClaudeTheme.size(12), weight: .medium, design: .monospaced))
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .frame(height: 28)
        .padding(.bottom, 4)
        .background(ClaudeTheme.surfacePrimary)
        .overlay(alignment: .top) {
            ClaudeTheme.borderSubtle.frame(height: 0.5)
        }
        .task {
            await refreshRateLimit()
            // Retry after 5 seconds if initial load fails
            if rateLimit == nil {
                try? await Task.sleep(for: .seconds(5))
                await refreshRateLimit()
            }
        }
        .onChange(of: chatBridge.isStreaming) { old, new in
            if old && !new {
                Task { await refreshRateLimit() }
            }
        }
        .onChange(of: chatBridge.agentProvider) {
            rateLimit = nil
            Task { await refreshRateLimit() }
        }
    }

    // MARK: - Version Segment

    @ViewBuilder
    private func versionSegment() -> some View {
        if let cli = currentRuntimeVersion {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text("\(currentRuntimeShortName) \(cli)")
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private var currentRuntimeVersion: String? {
        switch chatBridge.agentProvider {
        case .claudeCode: return chatBridge.claudeVersion
        case .codex: return chatBridge.codexVersion
        case .acp: return nil
        }
    }

    private var currentRuntimeShortName: String {
        switch chatBridge.agentProvider {
        case .claudeCode: return "CC"
        case .codex: return "Codex"
        case .acp: return "ACP"
        }
    }

    // MARK: - Provider Menu

    private func providerMenuSegment() -> some View {
        Menu {
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                Button {
                    chatBridge.setSessionProvider(provider)
                } label: {
                    Text(provider.displayName)
                    if chatBridge.agentProvider == provider {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatBridge.agentProvider == .codex ? "chevron.left.forwardslash.chevron.right" : "cpu")
                    .font(.system(size: ClaudeTheme.size(10)))
                Text(chatBridge.agentProvider.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .foregroundStyle(ClaudeTheme.statusSuccess)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Client: \(chatBridge.agentProvider.displayName)")
    }

    // MARK: - Usage Segments

    @ViewBuilder
    private func usageSegments() -> some View {
        switch chatBridge.agentProvider {
        case .claudeCode:
            rateLimitSegment(
                label: String(localized: "5h", bundle: .module),
                icon: "clock",
                percent: rateLimit?.fiveHourPercent,
                resetsAt: rateLimit?.fiveHourResetsAt,
                isPresented: $showFiveHourPopover,
                title: "5-hour rate limit",
                body: "Tracks usage against Anthropic's rolling 5-hour limit. Resets gradually as older requests age out."
            )
            rateLimitSegment(
                label: String(localized: "7d", bundle: .module),
                icon: "calendar",
                percent: rateLimit?.sevenDayPercent,
                resetsAt: rateLimit?.sevenDayResetsAt,
                isPresented: $showSevenDayPopover,
                title: "7-day rate limit",
                body: "Tracks usage against Anthropic's rolling 7-day limit. Resets gradually as older requests age out."
            )
        case .codex:
            rateLimitSegment(
                label: String(localized: "5h", bundle: .module),
                icon: "clock",
                percent: rateLimit?.fiveHourPercent,
                resetsAt: rateLimit?.fiveHourResetsAt,
                isPresented: $showFiveHourPopover,
                title: "5-hour rate limit",
                body: "Tracks usage against Codex's rolling 5-hour limit. Resets gradually as older requests age out."
            )
            rateLimitSegment(
                label: String(localized: "24h", bundle: .module),
                icon: "calendar",
                percent: rateLimit?.twentyFourHourPercent,
                resetsAt: rateLimit?.twentyFourHourResetsAt,
                isPresented: $showSevenDayPopover,
                title: "24-hour rate limit",
                body: "Tracks usage against Codex's rolling 24-hour limit. Resets gradually as older requests age out."
            )
        case .acp:
            EmptyView()
        }
    }

    // MARK: - Rate Limit Segment

    @ViewBuilder
    private func rateLimitSegment(
        label: String,
        icon: String,
        percent: Double?,
        resetsAt: Date?,
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        body: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: ClaudeTheme.size(10)))
            Text(label)
                .foregroundStyle(ClaudeTheme.textTertiary)
            if let pct = percent {
                miniBar(percent: pct)
                Text("\(Int(pct))%")
                    .foregroundStyle(colorForPercent(pct))
                if let resets = resetsAt {
                    Text(shortCountdown(until: resets))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            } else {
                Text("--")
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isPresented.wrappedValue.toggle() }
        .popover(isPresented: isPresented, arrowEdge: .top) {
            descriptionPopover(title: title, body: body, percent: percent, resetsAt: resetsAt)
        }
    }

    // MARK: - Context Segment

    @ViewBuilder
    private func contextSegment() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: ClaudeTheme.size(10)))
            Text("context", bundle: .module)
            if let ctxPct = contextPercentage {
                miniBar(percent: ctxPct)
                Text("\(Int(ctxPct))%")
                    .foregroundStyle(colorForPercent(ctxPct))
            } else {
                Text("--")
            }
        }
        .foregroundStyle(ClaudeTheme.textTertiary)
        .contentShape(Rectangle())
        .onTapGesture { showContextPopover.toggle() }
        .popover(isPresented: $showContextPopover, arrowEdge: .top) {
            descriptionPopover(
                title: "Context window",
                body: "Portion of the current conversation's context window in use. When it fills, older messages may be summarized or dropped.",
                percent: contextPercentage,
                resetsAt: nil
            )
        }
    }

    // MARK: - Description Popover

    @ViewBuilder
    private func descriptionPopover(
        title: LocalizedStringKey,
        body: LocalizedStringKey,
        percent: Double?,
        resetsAt: Date?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title, bundle: .module)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(body, bundle: .module)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pct = percent {
                Divider()
                    .padding(.vertical, 2)
                HStack(spacing: 6) {
                    Text("Currently at \(Int(pct))%", bundle: .module)
                        .foregroundStyle(colorForPercent(pct))
                    if let resets = resetsAt, resets.timeIntervalSinceNow > 0 {
                        Text("·")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text("Resets in \(shortCountdown(until: resets))", bundle: .module)
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
    }

    // MARK: - Mini Progress Bar

    private func miniBar(percent: Double, width: Int = 5) -> some View {
        let filled = max(0, min(width, Int((percent / 100.0) * Double(width))))
        let empty = width - filled
        let color = colorForPercent(percent)

        return HStack(spacing: 1) {
            ForEach(0..<filled, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 4, height: 10)
            }
            ForEach(0..<empty, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(ClaudeTheme.borderSubtle)
                    .frame(width: 4, height: 10)
            }
        }
    }

    // MARK: - Helpers

    private func colorForPercent(_ pct: Double) -> Color {
        if pct >= 90 { return ClaudeTheme.statusError }
        if pct >= 70 { return ClaudeTheme.statusWarning }
        return ClaudeTheme.statusSuccess
    }

    private func makeCountdownFormatter() -> DateComponentsFormatter {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.day, .hour, .minute]
        f.calendar = Calendar.current
        return f
    }

    private func shortCountdown(until date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "" }
        return makeCountdownFormatter().string(from: remaining) ?? ""
    }

    private func formatTotalDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        return f.string(from: seconds) ?? "—"
    }

    private func refreshRateLimit() async {
        rateLimit = await chatBridge.fetchRateLimit()
    }
}
