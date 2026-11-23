import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct MainWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
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
                    .environment(workspaceManager)
                    .environment(chatBridge)
                    .modifier(WorkspaceBrowserHost(appState: appState, windowState: windowState))
                    .generatedVideoSheet(windowState)
                    .environment(appState)
                    .environment(windowState)
                    .localStudioSettingsSheet(windowState, appState: appState)
                    .transition(.opacity)
            } else {
                LoadingView()
                    .transition(.opacity)
            }
        }
        // Prefer the workspace's open window when WidgetKit delivers a URL.
        // Without this preference SwiftUI creates a new WindowGroup instance.
        .handlesExternalEvents(
            preferring: ["rxcode://widget/tasks?workspace=\(workspaceID)", "rxcode://widget/usage?workspace=\(workspaceID)"],
            allowing: ["*"]
        )
        .onOpenURL { url in
            if let request = LocalModelSheetRequest.parse(url) {
                appState.localModelSheetRequest = request
                return
            }
            if url.scheme == "rxcode", url.host == "widget",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let targetID = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
               workspaceManager.workspaces.contains(where: { $0.id == targetID }) {
                let target = workspaceManager.appState(for: targetID)
                target.desktopWidgetNavigationURL = url
                if targetID == workspaceID {
                    consumeDesktopWidgetNavigation()
                } else {
                    openWindow(id: "workspace-window", value: WorkspaceWindowValue(workspaceID: targetID))
                }
                return
            }
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
        .onChange(of: appState.desktopWidgetNavigationURL) { _, _ in
            consumeDesktopWidgetNavigation()
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
            consumeDesktopWidgetNavigation()
            if !AppSupport.isUnitTesting {
                await NotificationService.shared.requestAuthorizationIfNeeded()
            }
            NotificationService.shared.onNotificationTapped = { projectId, sessionId in
                appState.handleNotificationTap(projectId: projectId, sessionId: sessionId, mainWindow: windowState)
            }
        }
    }

    private func consumeDesktopWidgetNavigation() {
        guard windowState.isInitialized, let url = appState.desktopWidgetNavigationURL else { return }
        appState.desktopWidgetNavigationURL = nil
        _ = appState.handleDesktopWidgetURL(url, in: windowState)
    }
}
