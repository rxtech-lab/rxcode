import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let inProgress = appState.inProgressSessionCount
        let provider = appState.selectedAgentProvider
        let usage = provider == .codex ? appState.latestCodexRateLimitUsage : appState.latestRateLimitUsage
        let fiveHour = usage?.fiveHourPercent
        let _ = appState.ciStatusRevision
        let ciFailing = appState.anyCIFailing

        if let image = Self.renderLabelImage(agentText: Self.agentText(for: provider), fiveHour: fiveHour, inProgress: inProgress, ciFailing: ciFailing) {
            Image(nsImage: image)
        } else {
            Image(systemName: "message")
        }
    }

    @MainActor
    private static func renderLabelImage(agentText: String, fiveHour: Double?, inProgress: Int, ciFailing: Bool) -> NSImage? {
        let content = MenuBarLabelContent(
            agentText: agentText,
            fiveHourText: fiveHour.map { "\(formatPercent($0))%" } ?? "—%",
            statusText: inProgress > 0 ? "\(inProgress)job\(inProgress == 1 ? "" : "s")" : "IDLE",
            ciFailing: ciFailing
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cgImage = renderer.cgImage else { return nil }
        let size = NSSize(width: CGFloat(cgImage.width) / renderer.scale,
                          height: CGFloat(cgImage.height) / renderer.scale)
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = true
        return image
    }

    private static func agentText(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "CC"
        case .codex: return "CODEX"
        case .acp: return "ACP"
        }
    }

    private static func formatPercent(_ value: Double) -> String {
        if value > 0 && value < 1 {
            return String(format: "%.1f", value)
        }
        return "\(Int(value.rounded()))"
    }
}

private struct MenuBarLabelContent: View {
    private static let textSize: CGFloat = 9

    let agentText: String
    let fiveHourText: String
    let statusText: String
    let ciFailing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(agentText)
                .font(.system(size: Self.textSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 18, alignment: .center)

            VStack(alignment: .leading, spacing: -1) {
                usageLine
                Text(statusText)
                    .font(.system(size: Self.textSize, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            // Template-rendered, so this shows as a monochrome glyph rather than
            // a red dot — the icon shape signals the CI failure.
            if ciFailing {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: Self.textSize + 1, weight: .bold))
                    .frame(height: 18, alignment: .center)
            }
        }
        .padding(.vertical, 1)
        .fixedSize(horizontal: true, vertical: true)
        .foregroundStyle(.black)
    }

    private var usageLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(fiveHourText)
                .font(.system(size: Self.textSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("5h")
                .font(.system(size: Self.textSize, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Menu Bar Content

struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isRefreshing = false
    @State private var showCreateWorkspaceSheet = false
    @State private var showManageWorkspaceSheet = false

    private var selectedUsage: RateLimitUsage? {
        switch appState.selectedAgentProvider {
        case .claudeCode: return appState.latestRateLimitUsage
        case .codex: return appState.latestCodexRateLimitUsage
        case .acp: return nil
        }
    }

    private var secondaryLimitLabel: String {
        switch appState.selectedAgentProvider {
        case .claudeCode: return "7-day limit"
        case .codex: return "7-day limit"
        case .acp: return "Usage"
        }
    }

    private var secondaryLimitPercent: Double? {
        switch appState.selectedAgentProvider {
        case .claudeCode: return selectedUsage?.sevenDayPercent
        case .codex: return selectedUsage?.sevenDayPercent
        case .acp: return nil
        }
    }

    private var secondaryLimitResetsAt: Date? {
        switch appState.selectedAgentProvider {
        case .claudeCode: return selectedUsage?.sevenDayResetsAt
        case .codex: return selectedUsage?.sevenDayResetsAt
        case .acp: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSwitcher(
                showingCreateSheet: $showCreateWorkspaceSheet,
                showingManageSheet: $showManageWorkspaceSheet
            )
            header
            agentPicker

            VStack(alignment: .leading, spacing: 12) {
                if selectedUsage?.hasFiveHourLimit ?? true {
                    MenuBarUsageBar(
                        label: "5-hour limit",
                        percent: selectedUsage?.fiveHourPercent,
                        resetsAt: selectedUsage?.fiveHourResetsAt,
                        emptyText: emptyUsageText
                    )
                }

                MenuBarUsageBar(
                    label: secondaryLimitLabel,
                    percent: secondaryLimitPercent,
                    resetsAt: secondaryLimitResetsAt,
                    emptyText: emptyUsageText
                )
            }

            Divider()

            chatActivitySection

            if !ciStatusRows.isEmpty {
                Divider()
                ciStatusSection
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 280)
        .sheet(isPresented: $showCreateWorkspaceSheet) {
            CreateWorkspaceSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showManageWorkspaceSheet) {
            ManageWorkspacesSheet()
                .environment(appState)
        }
        .task {
            await appState.refreshSelectedAgentRateLimitUsage()
        }
        .onChange(of: appState.selectedAgentProvider) {
            Task { await appState.refreshSelectedAgentRateLimitUsage() }
        }
    }

    private var header: some View {
        HStack {
            Text("\(appState.selectedAgentProvider.displayNameText) Usage")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await appState.refreshSelectedAgentRateLimitUsage(forceRefresh: true)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
        }
    }

    private var chatActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("In progress")
                    .font(.system(size: ClaudeTheme.size(12)))
                Spacer()
                Text("\(appState.inProgressSessionCount)")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Text("Awaiting check")
                    .font(.system(size: ClaudeTheme.size(12)))
                Spacer()
                Text("\(appState.uncheckedFinishedSessionCount)")
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentPicker: some View {
        Picker("Client", selection: Binding(
            get: { appState.selectedAgentProvider },
            set: { provider in
                appState.setDefaultAgentProvider(provider)
                Task { await appState.refreshSelectedAgentRateLimitUsage() }
            }
        )) {
            // ACP has no usage tracking, so it isn't offered in the menubar picker.
            ForEach(AgentProvider.allCases.filter { $0 != .acp }, id: \.self) { provider in
                Text(provider.displayName)
                    .tag(provider)
            }
        }
        .pickerStyle(.segmented)
    }

    private var emptyUsageText: String {
        switch appState.selectedAgentProvider {
        case .claudeCode: return "Sign in to Claude Code to see usage"
        case .codex: return "Sign in to Codex to see usage"
        case .acp: return "Usage tracking not supported by ACP"
        }
    }

    /// Maximum CI rows shown in the menubar popover. `ciStatusList()` sorts
    /// failures first, so the cap never hides a failing project behind a passing one.
    private static let maxCIStatusRows = 5

    private var ciStatusRows: [(project: Project, status: ProjectCIStatus)] {
        _ = appState.ciStatusRevision
        return Array(appState.ciStatusList().prefix(Self.maxCIStatusRows))
    }

    private var ciStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CI Status")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            ForEach(ciStatusRows, id: \.project.id) { row in
                CIStatusRow(
                    row: row,
                    destinationURL: ciDestinationURL(for: row.status),
                    help: ciRowHelp(for: row.status)
                )
            }
        }
    }

    /// Where a CI row should navigate when clicked: the pull request if one is
    /// associated with the branch, otherwise the failing workflow run on GitHub.
    private func ciDestinationURL(for status: ProjectCIStatus) -> URL? {
        if let prNumber = status.prNumber {
            return URL(string: "https://github.com/\(status.owner)/\(status.repo)/pull/\(prNumber)")
        }
        if let urlString = status.failing.first?.htmlUrl {
            return URL(string: urlString)
        }
        return nil
    }

    private func ciRowHelp(for status: ProjectCIStatus) -> String {
        if let prNumber = status.prNumber {
            return "Open PR #\(prNumber) on GitHub"
        }
        return "Open failing run on GitHub"
    }

    private var footer: some View {
        HStack {
            Button("Open RxCode") {
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            .font(.system(size: ClaudeTheme.size(12)))

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
            .font(.system(size: ClaudeTheme.size(12)))
            .foregroundStyle(.secondary)
        }
    }
}

/// A single CI-status row in the menubar popover. Clickable rows (those with a
/// `destinationURL`) draw a menu-style highlight on hover — the `.window`
/// MenuBarExtra style gives no automatic hover effect, so we track it manually.
private struct CIStatusRow: View {
    let row: (project: Project, status: ProjectCIStatus)
    let destinationURL: URL?
    let help: String

    @State private var isHovering = false

    private var isLink: Bool { destinationURL != nil }

    var body: some View {
        content
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering && isLink ? Color.primary.opacity(0.1) : .clear)
            )
            // Extend the highlight past the row's text inset, like a native menu item.
            .padding(.horizontal, -6)
            .onHover { hovering in
                isHovering = hovering
                guard isLink else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                if let url = destinationURL { NSWorkspace.shared.open(url) }
            }
            .help(isLink ? help : "")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: row.status.overallState.sfSymbolName)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(row.status.overallState.displayColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.project.name)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                if let branch = row.status.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isLink {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            } else {
                Text(row.status.overallState.label)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Usage Bar

private struct MenuBarUsageBar: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))

                Spacer()

                if let percent {
                    Text("\(formatPercent(percent))%")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ClaudeTheme.surfaceSecondary)
                        .frame(height: 6)

                    if let percent {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(for: percent))
                            .frame(width: max(0, min(1, percent / 100)) * geo.size.width, height: 6)
                    }
                }
            }
            .frame(height: 6)

            if let resetsAt, percent != nil {
                Text("Resets \(Self.resetFormatter.localizedString(for: resetsAt, relativeTo: Date()))")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.tertiary)
            } else if percent == nil {
                Text(emptyText)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatPercent(_ value: Double) -> String {
        if value > 0 && value < 1 {
            return String(format: "%.1f", value)
        }
        return "\(Int(value.rounded()))"
    }

    private func barColor(for percent: Double) -> Color {
        switch percent {
        case ..<60: return ClaudeTheme.accent
        case ..<85: return .orange
        default: return .red
        }
    }

    private static let resetFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .current
        f.unitsStyle = .abbreviated
        return f
    }()
}
