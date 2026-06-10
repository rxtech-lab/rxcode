import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - FocusedValues

private struct StartNewChatKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var startNewChat: (() -> Void)? {
        get { self[StartNewChatKey.self] }
        set { self[StartNewChatKey.self] = newValue }
    }
}

// MARK: - WorkspaceWindowValue

/// Identifies which workspace a main window is bound to. The primary
/// `WindowGroup` is keyed by this value so each workspace gets its own window
/// (and its own `AppState`), and reopening the same workspace refocuses its
/// existing window rather than spawning a duplicate.
struct WorkspaceWindowValue: Codable, Hashable {
    let workspaceID: String
}

// MARK: - ProjectWindowValue

struct ProjectWindowValue: Codable, Hashable {
    let projectId: UUID
    let instanceId: UUID
    /// Workspace that owns this project, so a detached project window resolves
    /// the correct per-workspace `AppState`.
    var workspaceID: String?
}

// MARK: - TerminalWindowValue

struct TerminalWindowValue: Codable, Hashable {
    let path: String
}

// MARK: - App

@main
struct RxCodeApp: App {
    @State private var workspaceManager = WorkspaceManager()
    @FocusedValue(\.startNewChat) private var startNewChat
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true
    private let updateService = UpdateService.shared

    init() {
        FirebaseBootstrap.configure()
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// AppState for the frontmost workspace window. Global scenes (Settings,
    /// menu bar, the Theme command) act on whichever workspace is currently key.
    private var appState: AppState { workspaceManager.frontmostAppState }

    var body: some Scene {
        WindowGroup(id: "workspace-window", for: WorkspaceWindowValue.self) { $value in
            MainWindowRoot(
                workspaceManager: workspaceManager,
                workspaceID: value.workspaceID
            )
            .focusable(false)
        } defaultValue: {
            WorkspaceWindowValue(workspaceID: workspaceManager.frontmostWorkspaceID)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    startNewChat?()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateService.checkForUpdates()
                }
            }
            CommandMenu("Theme") {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        appState.selectedTheme = theme
                    } label: {
                        Text(theme.displayName)
                    }
                    .disabled(appState.selectedTheme == theme)
                }
            }
            AutomationCommands()
            DocumentationCommands(appState: appState)
        }

        // Dedicated project window — opened on double-click
        WindowGroup(id: "project-window", for: ProjectWindowValue.self) { $value in
            if let id = value?.projectId {
                ProjectWindowRoot(
                    workspaceManager: workspaceManager,
                    workspaceID: value?.workspaceID ?? workspaceManager.frontmostWorkspaceID,
                    projectId: id
                )
                .focusable(false)
            }
        }
        .defaultSize(width: 1000, height: 700)

        // Detached terminal window — opened from the toolbar.
        WindowGroup(id: "terminal-window", for: TerminalWindowValue.self) { $value in
            TerminalWindowRoot(path: value?.path ?? "")
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsWindowRoot(appState: appState)
        }

        // Standalone Automation windows, opened from the "Automation" menu.
        Window("Autopilot", id: "autopilot-window") {
            AutopilotWindowRoot(appState: appState)
        }
        .defaultSize(width: 720, height: 640)

        Window("Hooks", id: "hooks-window") {
            HooksWindowRoot(appState: appState)
        }
        .defaultSize(width: 760, height: 620)

        Window("Custom Context Menus", id: "custom-menus-window") {
            CustomMenusWindowRoot(appState: appState)
        }
        .defaultSize(width: 720, height: 620)

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContentView()
                .environment(appState)
                .environment(workspaceManager)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

private struct MenuBarLabel: View {
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

private struct MenuBarContentView: View {
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
                MenuBarUsageBar(
                    label: "5-hour limit",
                    percent: selectedUsage?.fiveHourPercent,
                    resetsAt: selectedUsage?.fiveHourResetsAt,
                    emptyText: emptyUsageText
                )

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
            ForEach(AgentProvider.allCases, id: \.self) { provider in
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

    private var ciStatusRows: [(project: Project, status: ProjectCIStatus)] {
        _ = appState.ciStatusRevision
        return appState.ciStatusList()
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

// MARK: - Main Window Root

struct MainWindowRoot: View {
    let workspaceManager: WorkspaceManager
    let workspaceID: String
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    private var appState: AppState { workspaceManager.appState(for: workspaceID) }

    var body: some View {
        ZStack {
            if appState.isInitialized {
                MainView()
                    .environment(appState)
                    .environment(workspaceManager)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, OpenURLAction { url in
                        if let docs = DocsDeepLink.parse(url), docs.action == .setup {
                            appState.docsSetupRequest = DocsSetupRequest(repoFullName: docs.repoFullName)
                            return .handled
                        }
                        if let release = ReleaseDeepLink.parse(url), release.action == .setup {
                            appState.releaseSetupRequest = ReleaseSetupRequest(repoFullName: release.repoFullName)
                            return .handled
                        }
                        if let request = SecretsDeepLink.parse(url) {
                            appState.secretsSetupRequest = request
                            return .handled
                        }
                        if let request = CIUpdateDeepLink.parse(url) {
                            appState.ciSetupRequest = request
                            return .handled
                        }
                        return openMarkdownLink(url, in: windowState)
                    })
                    .transition(.opacity)
            } else {
                LoadingView()
                    .transition(.opacity)
            }
        }
        .onOpenURL { url in
            if let docs = DocsDeepLink.parse(url), docs.action == .setup {
                appState.docsSetupRequest = DocsSetupRequest(repoFullName: docs.repoFullName)
            } else if let release = ReleaseDeepLink.parse(url), release.action == .setup {
                appState.releaseSetupRequest = ReleaseSetupRequest(repoFullName: release.repoFullName)
            } else if let request = SecretsDeepLink.parse(url) {
                appState.secretsSetupRequest = request
            } else if let request = CIUpdateDeepLink.parse(url) {
                appState.ciSetupRequest = request
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
        .onAppear { workspaceManager.markFrontmost(workspaceID) }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { workspaceManager.markFrontmost(workspaceID) }
        }
        .task {
            await appState.initialize()
            appState.setupChatBridge(chatBridge, for: windowState)
            await appState.initializeWindow(windowState)
            await NotificationService.shared.requestAuthorizationIfNeeded()
            NotificationService.shared.onNotificationTapped = { projectId, sessionId in
                appState.handleNotificationTap(projectId: projectId, sessionId: sessionId, mainWindow: windowState)
            }
        }
    }
}

@MainActor
private func openMarkdownLink(_ url: URL, in windowState: WindowState) -> OpenURLAction.Result {
    if let fileLink = LocalFileLink.parse(url) {
        let fileName = URL(fileURLWithPath: fileLink.path).lastPathComponent
        windowState.inspectorFile = PreviewFile(
            path: fileLink.path,
            name: fileName.isEmpty ? fileLink.path : fileName
        )
        return .handled
    }

    var finalURL = url
    if url.scheme == nil || url.scheme!.isEmpty {
        finalURL = URL(string: "https://\(url.absoluteString)") ?? url
    }
    NSWorkspace.shared.open(finalURL)
    return .handled
}

// MARK: - Settings Window Root

struct SettingsWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()

    var body: some View {
        SettingsView()
            .environment(appState)
            .environment(windowState)
    }
}

// MARK: - Automation Commands

/// "Automation" menu in the top menu bar, opening the Autopilot, Hooks, and
/// Custom Context Menu management UIs as standalone windows.
struct AutomationCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Automation") {
            Button("Autopilot") { openWindow(id: "autopilot-window") }
            Button("Hooks") { openWindow(id: "hooks-window") }
            Button("Custom Context Menus") { openWindow(id: "custom-menus-window") }
        }
    }
}

// MARK: - Automation Window Roots

struct AutopilotWindowRoot: View {
    let appState: AppState

    var body: some View {
        AutopilotSettingsTab()
            .environment(appState)
            .frame(minWidth: 560, minHeight: 480)
    }
}

struct HooksWindowRoot: View {
    let appState: AppState

    var body: some View {
        ScrollView {
            HooksSettingsSection()
                .environment(appState)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct CustomMenusWindowRoot: View {
    let appState: AppState

    var body: some View {
        ScrollView {
            CustomMenusSettingsSection()
                .environment(appState)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Project Window Root

struct ProjectWindowRoot: View {
    let workspaceManager: WorkspaceManager
    let workspaceID: String
    let projectId: UUID
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    private var appState: AppState { workspaceManager.appState(for: workspaceID) }

    var body: some View {
        ZStack {
            if appState.isInitialized {
                MainView()
                    .environment(appState)
                    .environment(workspaceManager)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, OpenURLAction { url in
                        if let docs = DocsDeepLink.parse(url), docs.action == .setup {
                            appState.docsSetupRequest = DocsSetupRequest(repoFullName: docs.repoFullName)
                            return .handled
                        }
                        if let release = ReleaseDeepLink.parse(url), release.action == .setup {
                            appState.releaseSetupRequest = ReleaseSetupRequest(repoFullName: release.repoFullName)
                            return .handled
                        }
                        if let request = SecretsDeepLink.parse(url) {
                            appState.secretsSetupRequest = request
                            return .handled
                        }
                        if let request = CIUpdateDeepLink.parse(url) {
                            appState.ciSetupRequest = request
                            return .handled
                        }
                        return openMarkdownLink(url, in: windowState)
                    })
                    .transition(.opacity)
            } else {
                LoadingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
        .onAppear {
            windowState.isProjectWindow = true
            workspaceManager.markFrontmost(workspaceID)
            appState.registerOpenProjectWindow(projectId)
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { workspaceManager.markFrontmost(workspaceID) }
        }
        .onDisappear { appState.unregisterOpenProjectWindow(projectId) }
        .task {
            // Wait for the main window's AppState.initialize() to finish before
            // running per-window setup. State-restoration can spawn this window
            // before the main window has finished booting.
            while !appState.isInitialized {
                try? await Task.sleep(nanoseconds: 50000000)
            }
            windowState.isProjectWindow = true
            appState.setupChatBridge(chatBridge, for: windowState)
            await appState.initializeWindow(windowState, selectingProjectId: projectId)
            // Apply pending notification navigation (new window case)
            if let sessionId = appState.pendingNotificationSession.removeValue(forKey: projectId) {
                windowState.currentSessionId = sessionId
            }
        }
        // Apply pending notification navigation (already-open window case)
        .onChange(of: appState.pendingNotificationSession[projectId]) { _, sessionId in
            guard let sessionId else { return }
            windowState.currentSessionId = sessionId
            appState.pendingNotificationSession.removeValue(forKey: projectId)
        }
    }
}

// MARK: - Terminal Window Root

struct TerminalWindowRoot: View {
    let path: String
    @State private var process = TerminalProcess()
    @State private var resetID = UUID()
    @State private var focusID: UUID? = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .foregroundStyle(ClaudeTheme.accent)
                Text(path.isEmpty ? "Terminal" : URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer()

                Button {
                    process.terminate()
                    process = TerminalProcess()
                    resetID = UUID()
                    focusID = UUID()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Reset Terminal")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ClaudeThemeDivider()

            EmbeddedTerminalView(
                executable: "/bin/zsh",
                arguments: ["-il"],
                currentDirectory: path.isEmpty ? nil : path,
                process: process,
                focusTrigger: focusID
            )
            .id(resetID)
            .padding(8)
            .background(ClaudeTheme.codeBackground)
        }
        .frame(minWidth: 600, idealWidth: 900, minHeight: 400, idealHeight: 600)
        .background(ClaudeTheme.surfaceElevated)
    }
}
