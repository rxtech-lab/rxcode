import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - General Route Window Root

/// Standalone window hosting a single General route (Projects, Briefing, or
/// Scheduled) without the sidebar, with its own `WindowState` so it navigates
/// independently of the main window.
struct GeneralRouteWindowRoot: View {
    let workspaceManager: WorkspaceManager
    let workspaceID: String
    let route: GeneralRoute
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()
    @State private var isReady = false

    private var appState: AppState { workspaceManager.appState(for: workspaceID) }

    var body: some View {
        ZStack {
            if appState.isInitialized, windowState.isInitialized, isReady {
                GeneralRouteWindowView(route: route)
                    .hookUI()
                    .environment(appState)
                    .environment(workspaceManager)
                    .environment(windowState)
                    .environment(chatBridge)
                    .environment(\.openURL, workspaceOpenURLAction(appState: appState, windowState: windowState))
                    .transition(.opacity)
            } else {
                // Plain spinner rather than `LoadingView`: the splash hides the
                // window's title bar and traffic lights.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .animation(.easeInOut(duration: 0.3), value: isReady)
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
            windowState.generalRoute = route
            isReady = true
        }
    }
}

// MARK: - General Route Window View

/// Shows the route's page. Opening a thread from it (e.g. a briefing card or a
/// task's thread) clears the route; the thread then shows in place with a back
/// button that returns to the route.
private struct GeneralRouteWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    let route: GeneralRoute

    private var isShowingRoute: Bool {
        windowState.generalRoute != nil || windowState.selectedProject == nil
    }

    private var navigationTitleText: String {
        if !isShowingRoute,
           let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title,
           !title.isEmpty {
            return title
        }
        return (windowState.generalRoute ?? route).displayNameText
    }

    var body: some View {
        Group {
            if isShowingRoute {
                routeContent
            } else {
                threadContent
            }
        }
        .navigationTitle(navigationTitleText)
        .sheet(item: Bindable(windowState).inspectorFile) { file in
            FileInspectorView(filePath: file.path, fileName: file.name)
                .frame(minWidth: 1000, idealWidth: 1400, maxWidth: 1920,
                       minHeight: 600, idealHeight: 1000, maxHeight: 1200)
        }
        .sheet(item: Bindable(windowState).diffFile) { file in
            FileDiffView(
                filePath: file.path,
                fileName: file.name,
                editHunks: file.editHunks,
                gitDiffMode: file.gitDiffMode,
                showFullFileDiff: file.showFullFileDiff,
                originalContent: file.originalContent,
                modifiedContent: file.modifiedContent
            )
            .frame(minWidth: 1000, idealWidth: 1400, maxWidth: 1920,
                   minHeight: 600, idealHeight: 1000, maxHeight: 1200)
        }
        .sheet(isPresented: Binding(
            get: { windowState.linkCloudProjectId != nil },
            set: { if !$0 { windowState.linkCloudProjectId = nil } }
        )) {
            if let projectId = windowState.linkCloudProjectId {
                LinkCloudProjectSheet(projectId: projectId)
                    .environment(appState)
                    .environment(windowState)
            }
        }
        .sheet(isPresented: Bindable(windowState).showNewProjectSheet) {
            NewProjectSheet(prefersCloud: windowState.newProjectPrefersCloud)
                .environment(appState)
                .environment(windowState)
        }
        .alert("Error", isPresented: Bindable(windowState).showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(windowState.errorMessage ?? ""))
        }
        .focusedValue(\.startNewChat) {
            appState.startNewChat(in: windowState)
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch windowState.generalRoute ?? route {
        case .tasks: TaskBoardView()
        case .briefing: BriefingView()
        case .scheduled: ScheduledTasksView()
        case .chat: GlobalChatView()
        }
    }

    private var threadContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    windowState.generalRoute = route
                } label: {
                    Label(route.displayName, systemImage: "chevron.left")
                }
                .help("Back to \(route.displayNameText)")

                if let project = windowState.selectedProject, !project.isGlobalChat {
                    Label(project.name, systemImage: "folder")
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                        .help(project.path)
                }

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(12)

            ClaudeThemeDivider()

            ChatView(inputAccessory: {
                HStack(spacing: 8) {
                    ChatToolbarControls(placement: .composer)
                    if windowState.selectedProject?.isGlobalChat == false {
                        BranchPickerChip()
                    }
                }
            }, aboveInputAccessory: {
                VStack(spacing: 8) {
                    PermissionQueueBanner()
                    ThreadDiffBanner()
                }
            })
        }
        .modifier(ChatDetailModifiers())
    }
}
