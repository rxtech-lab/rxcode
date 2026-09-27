import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - FocusedValues

private struct StartNewChatKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ShowWhatsNewKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var startNewChat: (() -> Void)? {
        get { self[StartNewChatKey.self] }
        set { self[StartNewChatKey.self] = newValue }
    }

    var showWhatsNew: (() -> Void)? {
        get { self[ShowWhatsNewKey.self] }
        set { self[ShowWhatsNewKey.self] = newValue }
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

// MARK: - ChatWindowValue

/// Identifies a detached Chat-tab window. `instanceId` lets the user open
/// several independent chat windows for the same workspace.
struct ChatWindowValue: Codable, Hashable {
    let instanceId: UUID
    var workspaceID: String?
}

// MARK: - GeneralRouteWindowValue

/// Identifies a detached General-route window (Projects, Briefing, Scheduled)
/// opened from the sidebar row's context menu. `instanceId` lets the user open
/// several independent windows for the same route.
struct GeneralRouteWindowValue: Codable, Hashable {
    let route: GeneralRoute
    let instanceId: UUID
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
    @FocusedValue(\.showCacheStorage) private var showCacheStorage
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true
    private let updateService = UpdateService.shared

    init() {
        if !AppSupport.isTestProcess {
            FirebaseBootstrap.configure()
        }
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
            .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
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
                Button("Clear Cached Data…") { showCacheStorage?() }
                    .disabled(showCacheStorage == nil)
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
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
            }
        }
        .defaultSize(width: 1000, height: 700)

        // Detached chat window — opened from the sidebar Chat row's context menu.
        WindowGroup(id: "chat-window", for: ChatWindowValue.self) { $value in
            if let value {
                ChatWindowRoot(
                    workspaceManager: workspaceManager,
                    workspaceID: value.workspaceID ?? workspaceManager.frontmostWorkspaceID
                )
                .focusable(false)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
            }
        }
        .defaultSize(width: 800, height: 700)

        // Detached General-route window — opened from the sidebar Projects,
        // Briefing, and Scheduled rows' context menus.
        WindowGroup(id: "route-window", for: GeneralRouteWindowValue.self) { $value in
            if let value {
                GeneralRouteWindowRoot(
                    workspaceManager: workspaceManager,
                    workspaceID: value.workspaceID ?? workspaceManager.frontmostWorkspaceID,
                    route: value.route
                )
                .focusable(false)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
            }
        }
        .defaultSize(width: 1000, height: 700)

        // Detached terminal window — opened from the toolbar.
        WindowGroup(id: "terminal-window", for: TerminalWindowValue.self) { $value in
            TerminalWindowRoot(path: value?.path ?? "")
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsWindowRoot(appState: appState)
                .environment(workspaceManager)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
        }

        // Standalone Automation windows, opened from the "Automation" menu.
        Window("Autopilot", id: "autopilot-window") {
            AutopilotWindowRoot(appState: appState)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
        }
        .defaultSize(width: 720, height: 640)

        Window("Hooks", id: "hooks-window") {
            HooksWindowRoot(appState: appState)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
        }
        .defaultSize(width: 760, height: 620)

        Window("Custom Context Menus", id: "custom-menus-window") {
            CustomMenusWindowRoot(appState: appState)
                .modifier(CacheStoragePresenter(workspaceManager: workspaceManager))
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
                    .environment(\.openURL, workspaceOpenURLAction(appState: appState, windowState: windowState))
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
            if !AppSupport.isUnitTesting {
                await NotificationService.shared.requestAuthorizationIfNeeded()
            }
            NotificationService.shared.onNotificationTapped = { projectId, sessionId in
                appState.handleNotificationTap(projectId: projectId, sessionId: sessionId, mainWindow: windowState)
            }
        }
    }
}

/// `openURL` handler shared by full workspace windows: routes RxCode setup
/// deep links to the matching sheet and everything else to `openMarkdownLink`.
@MainActor
func workspaceOpenURLAction(appState: AppState, windowState: WindowState) -> OpenURLAction {
    OpenURLAction { url in
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
                    .environment(\.openURL, workspaceOpenURLAction(appState: appState, windowState: windowState))
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

// MARK: - Chat Window Root

/// Standalone window hosting only the global Chat tab, with its own
/// `WindowState` so it chats independently of the main window.
struct ChatWindowRoot: View {
    let workspaceManager: WorkspaceManager
    let workspaceID: String
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    private var appState: AppState { workspaceManager.appState(for: workspaceID) }

    var body: some View {
        ZStack {
            if appState.isInitialized, windowState.isInitialized {
                GlobalChatView()
                    .hookUI()
                    .environment(appState)
                    .environment(workspaceManager)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, OpenURLAction { url in
                        openMarkdownLink(url, in: windowState)
                    })
                    .navigationTitle(navigationTitleText)
                    .transition(.opacity)
            } else {
                // Plain spinner rather than `LoadingView`: the splash hides the
                // window's title bar and traffic lights, which this short-lived
                // loading phase could leave hidden.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .animation(.easeInOut(duration: 0.3), value: windowState.isInitialized)
        .onAppear { workspaceManager.markFrontmost(workspaceID) }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { workspaceManager.markFrontmost(workspaceID) }
        }
        .task {
            // The main window may still be booting AppState (e.g. on state restoration).
            while !appState.isInitialized {
                try? await Task.sleep(nanoseconds: 50000000)
            }
            appState.setupChatBridge(chatBridge, for: windowState)
            await appState.initializeWindow(windowState)
            appState.openGlobalChat(in: windowState)
        }
    }

    private var navigationTitleText: String {
        if let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title,
           !title.isEmpty {
            return title
        }
        return String(localized: "Chat")
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
