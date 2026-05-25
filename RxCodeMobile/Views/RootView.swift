import SwiftUI
import RxCodeSync
import os.log

private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "RootView")

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
    @State private var selectedBriefingGroup: BriefingGroupKey?
    @State private var briefingDetailPath = NavigationPath()
    @State private var showingBriefing = true
    @State private var showSettings = false
    @State private var selectedTab: MobileRootTab = .briefing
    @State private var projectsPath = NavigationPath()
    @State private var minimumLoadingTimeElapsed = false
    @State private var connectionTimedOut = false
    @State private var showPairingSheet = false

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
        .sheet(isPresented: $showPairingSheet) {
            NavigationStack {
                OnboardingView(showsCancelButton: true) {
                    showPairingSheet = false
                    connectionTimedOut = false
                    minimumLoadingTimeElapsed = false
                    Task {
                        await retryConnection()
                    }
                }
                .environmentObject(state)
                .navigationTitle("Pair New Mac")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .mobileDismissesKeyboardOnScroll()
    }

    /// Whether the loading splash should be dismissed (data loaded AND minimum time elapsed, but NOT timed out)
    private var shouldShowContent: Bool {
        let result = state.hasReceivedInitialSnapshot && minimumLoadingTimeElapsed && !connectionTimedOut
        logger.debug("shouldShowContent: \(result) (hasSnapshot: \(self.state.hasReceivedInitialSnapshot), minTimeElapsed: \(self.minimumLoadingTimeElapsed), timedOut: \(self.connectionTimedOut))")
        return result
    }

    private var paired: some View {
        ZStack {
            // Main content - always present but may be hidden
            mainContent
                .opacity(shouldShowContent ? 1 : 0)

            // Loading splash - shown until first snapshot AND minimum 2 seconds
            if !shouldShowContent {
                SyncLoadingView(
                    isTimedOut: connectionTimedOut,
                    pairedDesktops: state.pairedDesktops,
                    activeDesktopID: state.activePairedDesktop?.id,
                    onRetry: {
                        connectionTimedOut = false
                        Task {
                            await retryConnection()
                        }
                    },
                    onSelectDesktop: { desktop in
                        connectionTimedOut = false
                        minimumLoadingTimeElapsed = false
                        Task {
                            await state.switchPairedDesktop(desktop)
                            await retryConnection()
                        }
                    },
                    onPairNewDesktop: {
                        showPairingSheet = true
                    }
                )
                .transition(.splashTransition)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: shouldShowContent)
        .task {
            await initialLoad()
        }
        .onChange(of: state.activeSessionID) { _, newValue in
            openActiveSession(newValue)
        }
        .onChange(of: state.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        .onChange(of: state.hasReceivedInitialSnapshot) { oldValue, newValue in
            // Reset states when snapshot state resets (e.g., switching paired desktops)
            if oldValue && !newValue {
                minimumLoadingTimeElapsed = false
                connectionTimedOut = false
                Task {
                    await initialLoad()
                }
            }
        }
    }

    /// Performs initial load with timeout handling
    private func initialLoad() async {
        logger.info("initialLoad started, current hasReceivedInitialSnapshot: \(self.state.hasReceivedInitialSnapshot)")
        
        // Send the snapshot request (returns immediately, snapshot arrives async)
        consumePendingDeepLink()
        await state.refreshSnapshot()
        logger.info("Snapshot request sent")
        
        // Wait for either snapshot to arrive or timeout
        let timeoutSeconds = 15
        let pollIntervalMs: UInt64 = 100
        let maxPolls = (timeoutSeconds * 1000) / Int(pollIntervalMs)
        
        var pollCount = 0
        while !state.hasReceivedInitialSnapshot && pollCount < maxPolls {
            try? await Task.sleep(for: .milliseconds(pollIntervalMs))
            pollCount += 1
            if pollCount % 50 == 0 { // Log every 5 seconds
                logger.debug("Still waiting for snapshot... polls=\(pollCount)/\(maxPolls)")
            }
        }
        
        let hasSnapshot = state.hasReceivedInitialSnapshot
        logger.info("Wait completed: hasSnapshot=\(hasSnapshot), polls=\(pollCount)/\(maxPolls)")
        
        // Ensure minimum 2 second display time for smooth UX
        if pollCount < 20 { // Less than 2 seconds elapsed
            let remainingMs = (20 - pollCount) * Int(pollIntervalMs)
            logger.debug("Waiting additional \(remainingMs)ms for minimum display time")
            try? await Task.sleep(for: .milliseconds(remainingMs))
        }
        
        if hasSnapshot {
            logger.info("Connection successful - showing content")
            withAnimation {
                minimumLoadingTimeElapsed = true
            }
        } else {
            logger.warning("Connection timed out after \(timeoutSeconds)s - showing timeout screen")
            withAnimation {
                connectionTimedOut = true
                minimumLoadingTimeElapsed = true
            }
        }
    }

    /// Retry connection after timeout
    private func retryConnection() async {
        logger.info("Retry connection requested")
        await initialLoad()
    }

    private var mainContent: some View {
        Group {
            if compactClass == .compact {
                phoneTabs
            } else {
                ipadSplitView
            }
        }
    }

    private var phoneTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $briefingDetailPath) {
                MobileBriefingView(
                    onCloseChat: { closeBriefingChat() },
                    onOpenSession: { briefingDetailPath.append($0) }
                )
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
        } content: {
            BriefingListView(selectedGroup: $selectedBriefingGroup)
                .onChange(of: selectedBriefingGroup) { _, _ in
                    // Clear navigation path when switching briefing groups
                    briefingDetailPath.removeLast(briefingDetailPath.count)
                }
        } detail: {
            NavigationStack(path: $briefingDetailPath) {
                Group {
                    if let groupKey = selectedBriefingGroup {
                        MobileBriefingDetailView(
                            groupKey: groupKey,
                            onOpenSession: { briefingDetailPath.append($0) }
                        )
                    } else {
                        ContentUnavailableView {
                            Label("No Selection", systemImage: "doc.text")
                        } description: {
                            Text("Select a briefing to view details")
                        }
                    }
                }
                .navigationDestination(for: String.self) { sessionID in
                    MobileChatView(sessionID: sessionID, onClose: { closeBriefingChat() })
                        .id(sessionID)
                        .task(id: sessionID) {
                            if !MobileDraftSessionID.isDraft(sessionID) {
                                await state.subscribe(to: sessionID)
                            }
                        }
                }
            }
        }
    }

    private func closeBriefingChat() {
        if !briefingDetailPath.isEmpty {
            briefingDetailPath.removeLast()
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
        // Skip navigation if we're already inside the briefing detail flow.
        if isViewingBriefingDetail {
            return
        }
        navigate(toSession: sessionID, projectID: nil)
    }

    private var isViewingBriefingDetail: Bool {
        guard !briefingDetailPath.isEmpty else { return false }
        if compactClass == .compact {
            return selectedTab == .briefing
        }
        return showingBriefing
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
        selectedTab = .projects
        showingBriefing = false

        // Resolve the owning project so the navigation stack keeps its
        // Projects → Threads → Chat hierarchy. Draft sessions encode the
        // project in their ID; synced sessions are looked up in `state`.
        let resolvedProjectID = projectID
            ?? state.sessions.first(where: { $0.id == sessionID })?.projectId
            ?? MobileDraftSessionID.projectID(from: sessionID)

        if compactClass == .compact {
            // Push the project level before the chat so the back button
            // returns to the thread list, not the project list.
            var path = NavigationPath()
            if let resolvedProjectID {
                path.append(resolvedProjectID)
            }
            path.append(sessionID)
            if projectsPath != path {
                projectsPath = path
            }
        } else {
            guard let resolvedProjectID else { return }
            selectedProject = resolvedProjectID
            selectedSession = sessionID
        }
    }
}
