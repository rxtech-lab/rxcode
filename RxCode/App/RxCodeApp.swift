import SwiftUI
import RxCodeCore
import RxCodeChatKit

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

// MARK: - ProjectWindowValue

struct ProjectWindowValue: Codable, Hashable {
    let projectId: UUID
    let instanceId: UUID
}

// MARK: - TerminalWindowValue

struct TerminalWindowValue: Codable, Hashable {
    let path: String
}

// MARK: - App

@main
struct RxCodeApp: App {
    @State private var appState = AppState()
    @FocusedValue(\.startNewChat) private var startNewChat
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true
    private let updateService = UpdateService.shared

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(appState: appState)
                .focusable(false)
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
                    Button(theme.displayName) {
                        appState.selectedTheme = theme
                    }
                    .disabled(appState.selectedTheme == theme)
                }
            }
        }

        // Dedicated project window — opened on double-click
        WindowGroup(id: "project-window", for: ProjectWindowValue.self) { $value in
            if let id = value?.projectId {
                ProjectWindowRoot(appState: appState, projectId: id)
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

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContentView()
                .environment(appState)
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

        if let image = Self.renderLabelImage(agentText: Self.agentText(for: provider), fiveHour: fiveHour, inProgress: inProgress) {
            Image(nsImage: image)
        } else {
            Image(systemName: "message")
        }
    }

    @MainActor
    private static func renderLabelImage(agentText: String, fiveHour: Double?, inProgress: Int) -> NSImage? {
        let content = MenuBarLabelContent(
            agentText: agentText,
            fiveHourText: fiveHour.map { "\(formatPercent($0))%" } ?? "—%",
            statusText: inProgress > 0 ? "\(inProgress)job\(inProgress == 1 ? "" : "s")" : "IDLE"
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
        case .codex: return "24-hour limit"
        case .acp: return "Usage"
        }
    }

    private var secondaryLimitPercent: Double? {
        switch appState.selectedAgentProvider {
        case .claudeCode: return selectedUsage?.sevenDayPercent
        case .codex: return selectedUsage?.twentyFourHourPercent
        case .acp: return nil
        }
    }

    private var secondaryLimitResetsAt: Date? {
        switch appState.selectedAgentProvider {
        case .claudeCode: return selectedUsage?.sevenDayResetsAt
        case .codex: return selectedUsage?.twentyFourHourResetsAt
        case .acp: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 280)
        .task {
            await appState.refreshSelectedAgentRateLimitUsage()
        }
        .onChange(of: appState.selectedAgentProvider) {
            Task { await appState.refreshSelectedAgentRateLimitUsage() }
        }
    }

    private var header: some View {
        HStack {
            Text("\(appState.selectedAgentProvider.displayName) Usage")
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
        default:    return .red
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
    let appState: AppState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        ZStack {
            if appState.isInitialized {
                MainView()
                    .environment(appState)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, OpenURLAction { url in
                        var finalURL = url
                        if url.scheme == nil || url.scheme!.isEmpty {
                            finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                        }
                        NSWorkspace.shared.open(finalURL)
                        return .handled
                    })
                    .transition(.opacity)
            } else {
                LoadingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
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

// MARK: - Project Window Root

struct ProjectWindowRoot: View {
    let appState: AppState
    let projectId: UUID
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        ZStack {
            if appState.isInitialized {
                MainView()
                    .environment(appState)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, OpenURLAction { url in
                        var finalURL = url
                        if url.scheme == nil || url.scheme!.isEmpty {
                            finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                        }
                        NSWorkspace.shared.open(finalURL)
                        return .handled
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
            appState.registerOpenProjectWindow(projectId)
        }
        .onDisappear { appState.unregisterOpenProjectWindow(projectId) }
        .task {
            // Wait for the main window's AppState.initialize() to finish before
            // running per-window setup. State-restoration can spawn this window
            // before the main window has finished booting.
            while !appState.isInitialized {
                try? await Task.sleep(nanoseconds: 50_000_000)
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
