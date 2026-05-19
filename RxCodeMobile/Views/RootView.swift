import SwiftUI
import RxCodeSync

/// Mobile app root. On iPad / wide screens this uses NavigationSplitView; on
/// iPhone it auto-collapses to a stack.
struct RootView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var selectedProject: UUID?
    @State private var selectedSession: String?
    @State private var showingBriefing = true
    @State private var showSettings = false

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
    }

    private var paired: some View {
        NavigationSplitView {
            ProjectsSidebar(selected: $selectedProject, showingBriefing: $showingBriefing)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
        } content: {
            if showingBriefing {
                MobileBriefingView()
            } else if let projectID = selectedProject {
                SessionsList(projectID: projectID, selected: $selectedSession)
            } else {
                Text("Select a project")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            if !showingBriefing, let sessionID = selectedSession {
                MobileChatView(sessionID: sessionID)
                    .id(sessionID)
            } else {
                Text("Select a thread")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            MobileSettingsView()
                .environmentObject(state)
        }
        .onChange(of: selectedSession) { _, newValue in
            Task { await state.subscribe(to: newValue) }
        }
        .onChange(of: selectedProject) { _, newValue in
            if newValue != nil {
                showingBriefing = false
            }
        }
    }
}
