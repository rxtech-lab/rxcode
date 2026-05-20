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
            await state.refreshSnapshot()
        }
        .onChange(of: state.activeSessionID) { _, newValue in
            openActiveSession(newValue)
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

    /// Navigate to a session surfaced by the desktop (deep links, notifications,
    /// freshly created threads). Compact mode is driven solely by `projectsPath`
    /// while the regular split view is driven by `selectedSession`. Keeping the
    /// two mechanisms separate avoids pushing the same chat page twice.
    private func openActiveSession(_ sessionID: String?) {
        guard let sessionID,
              let session = state.sessions.first(where: { $0.id == sessionID })
        else { return }

        selectedTab = .projects
        showingBriefing = false

        if compactClass == .compact {
            var path = NavigationPath()
            path.append(session.projectId)
            path.append(sessionID)
            if projectsPath != path {
                projectsPath = path
            }
        } else {
            selectedProject = session.projectId
            selectedSession = sessionID
        }
    }
}
