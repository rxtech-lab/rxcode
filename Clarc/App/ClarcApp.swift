import SwiftUI
import ClarcCore
import ClarcChatKit

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
struct ClarcApp: App {
    @State private var appState = AppState()
    @FocusedValue(\.startNewChat) private var startNewChat
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
    }
}

// MARK: - Main Window Root

struct MainWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
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
        ProjectWindowView()
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
            .task {
                // AppState is already initialized at this point
                appState.setupChatBridge(chatBridge, for: windowState)
                await appState.initializeWindow(windowState, selectingProjectId: projectId)
                // Apply pending notification navigation (new window case)
                if let sessionId = appState.pendingNotificationSession.removeValue(forKey: projectId) {
                    windowState.currentSessionId = sessionId
                }
            }
            .onAppear { appState.registerOpenProjectWindow(projectId) }
            .onDisappear { appState.unregisterOpenProjectWindow(projectId) }
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
