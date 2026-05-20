import SwiftUI
import RxCodeSync

private enum MobileRootTab: Hashable {
    case briefing
    case projects
    case settings
}

/// Mobile app root. iPad / wide screens use NavigationSplitView; iPhone uses
/// bottom navigation with independent NavigationStack tabs.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var compactClass
    @EnvironmentObject private var state: MobileAppState
    @State private var selectedProject: UUID?
    @State private var selectedSession: String?
    @State private var showingBriefing = true
    @State private var showSettings = false
    @State private var selectedTab: MobileRootTab = .briefing
    @State private var projectsPath = NavigationPath()

    var body: some View {
        Group {
            if state.isPaired {
                paired
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $state.pendingPermission) { req in
            PermissionApprovalSheet(request: req)
                .environmentObject(state)
        }
        .mobileDismissesKeyboardOnScroll()
    }

    private var paired: some View {
        Group {
            if compactClass == .compact {
                phoneTabs
            } else {
                ipadSplitView
            }
        }
        .task {
            consumePendingDeepLink()
            await state.refreshSnapshot()
        }
        .onChange(of: state.activeSessionID) { _, newValue in
            openActiveSession(newValue)
        }
        .onChange(of: state.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
    }

    private var phoneTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                MobileBriefingView()
            }
            .tabItem {
                Label("Briefing", systemImage: "doc.text")
            }
            .tag(MobileRootTab.briefing)

            NavigationStack(path: $projectsPath) {
                ProjectsSidebar(
                    selected: $selectedProject,
                    showingBriefing: $showingBriefing,
                    showsBriefingItem: false,
                    usesSelection: false
                )
                .navigationDestination(for: UUID.self) { projectID in
                    SessionsList(
                        projectID: projectID,
                        selected: $selectedSession,
                        usesSelection: false
                    )
                }
                .navigationDestination(for: String.self) { sessionID in
                    chatDestination(sessionID)
                }
            }
            .tabItem {
                Label("Projects", systemImage: "folder")
            }
            .tag(MobileRootTab.projects)

            MobileSettingsView(showsDoneButton: false)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(MobileRootTab.settings)
        }
    }

    private var ipadSplitView: some View {
        Group {
            if showingBriefing {
                briefingSplitView
            } else {
                projectSplitView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            MobileSettingsView()
                .environmentObject(state)
        }
        .onChange(of: selectedProject) { _, newValue in
            if newValue != nil {
                selectedSession = nil
                showingBriefing = false
            }
        }
    }

    private var briefingSplitView: some View {
        NavigationSplitView {
            projectSidebar
        } detail: {
            NavigationStack {
                MobileBriefingView()
            }
        }
    }

    private var projectSplitView: some View {
        NavigationSplitView {
            projectSidebar
        } content: {
            if let projectID = selectedProject {
                SessionsList(projectID: projectID, selected: $selectedSession)
            } else {
                Text("Select a project")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            if !showingBriefing, let sessionID = selectedSession {
                chatDestination(sessionID)
            } else {
                Text("Select a thread")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projectSidebar: some View {
        ProjectsSidebar(selected: $selectedProject, showingBriefing: $showingBriefing)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
    }

    private func chatDestination(_ sessionID: String) -> some View {
        MobileChatView(sessionID: sessionID, onClose: { closeChat() })
            .id(sessionID)
            .toolbar(.hidden, for: .tabBar)
            .task(id: sessionID) {
                if !MobileDraftSessionID.isDraft(sessionID) {
                    await state.subscribe(to: sessionID)
                }
            }
    }

    /// Pop the chat view after its thread is archived or deleted. Compact mode
    /// is driven by `projectsPath`; the split view by `selectedSession`.
    private func closeChat() {
        if compactClass == .compact {
            if !projectsPath.isEmpty { projectsPath.removeLast() }
        } else {
            selectedSession = nil
        }
    }

    /// Navigate to a session surfaced by the desktop (freshly created threads,
    /// desktop-driven focus changes).
    private func openActiveSession(_ sessionID: String?) {
        guard let sessionID else { return }
        navigate(toSession: sessionID, projectID: nil)
    }

    /// Consume a pending APNs deep link (set by a notification tap) and navigate
    /// to its thread. Called both when the link changes and when the paired view
    /// first appears, since a link can already be set at cold launch.
    private func consumePendingDeepLink() {
        guard let link = state.pendingDeepLink else { return }
        state.pendingDeepLink = nil
        navigate(toSession: link.sessionID, projectID: link.projectID)
    }

    /// Push the chat detail page for `sessionID`. Shared by desktop-driven
    /// navigation and APNs deep links. When `projectID` is supplied (notification
    /// payloads carry it) navigation works even before the session has synced
    /// into `state.sessions`; otherwise the project is looked up there.
    ///
    /// Compact mode is driven solely by `projectsPath` while the regular split
    /// view is driven by `selectedSession`. Keeping the two mechanisms separate
    /// avoids pushing the same chat page twice.
    private func navigate(toSession sessionID: String, projectID: UUID?) {
        guard let projectID = projectID
            ?? state.sessions.first(where: { $0.id == sessionID })?.projectId
        else { return }

        selectedTab = .projects
        showingBriefing = false

        if compactClass == .compact {
            var path = NavigationPath()
            path.append(projectID)
            path.append(sessionID)
            if projectsPath != path {
                projectsPath = path
            }
        } else {
            selectedProject = projectID
            selectedSession = sessionID
        }
    }
}
