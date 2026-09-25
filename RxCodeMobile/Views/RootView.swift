import os.log
import RxCodeCore
import RxCodeSync
import SwiftUI

private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "RootView")

private enum MobileRootTab: Hashable {
    case briefing
    case projects
    case tasks
    case settings
    case search
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
    @State private var showingBriefing = false
    @State private var showSettings = false
    @State private var showingTasks = true
    @State private var selectedTab: MobileRootTab = .tasks
    @State private var projectsPath = NavigationPath()
    /// Owned here (not by the stack) so the Tasks navigation survives layout
    /// changes, and so chats opened from a task push onto it.
    @State private var tasksPath = NavigationPath()
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
            .mobileSheetPresentation()
        }
        .mobileDismissesKeyboardOnScroll()
    }

    /// Whether the loading splash should be dismissed (data loaded AND minimum time elapsed, but NOT timed out)
    private var shouldShowContent: Bool {
        let result = state.hasReceivedInitialSnapshot && minimumLoadingTimeElapsed && !connectionTimedOut
        logger.debug("shouldShowContent: \(result) (hasSnapshot: \(state.hasReceivedInitialSnapshot), minTimeElapsed: \(minimumLoadingTimeElapsed), timedOut: \(connectionTimedOut))")
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
        logger.info("initialLoad started, current hasReceivedInitialSnapshot: \(state.hasReceivedInitialSnapshot)")

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
            if usesPhoneLayout {
                phoneTabs
            } else {
                ipadSplitView
            }
        }
    }

    @State private var searchText = ""

    /// iPhones keep the tab layout in every orientation. Large iPhones report a
    /// regular width in landscape, and swapping to the split view on rotation
    /// would rebuild every stack and drop the user's navigation.
    private var usesPhoneLayout: Bool {
        compactClass == .compact || UIDevice.current.userInterfaceIdiom == .phone
    }

    private var phoneTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Tasks", systemImage: "checklist", value: MobileRootTab.tasks) {
                tasksStack
            }

            Tab("Briefing", systemImage: "doc.text", value: MobileRootTab.briefing) {
                NavigationStack(path: $briefingDetailPath) {
                    MobileBriefingView(
                        onCloseChat: { closeBriefingChat() },
                        onOpenSession: { briefingDetailPath.append($0) }
                    )
                }
            }

            Tab("Projects", systemImage: "folder", value: MobileRootTab.projects) {
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
            }

            Tab("Settings", systemImage: "gear", value: MobileRootTab.settings) {
                MobileSettingsView(showsDoneButton: false)
            }

            Tab(value: MobileRootTab.search, role: .search) {
                NavigationStack {
                    MobileSearchContentView(searchText: $searchText)
                        .navigationTitle("Search")
                }
                .searchable(text: $searchText, prompt: "Search threads and docs")
            }
        }
    }

    private var ipadSplitView: some View {
        Group {
            if showingTasks {
                tasksSplitView
            } else if showingBriefing {
                briefingSplitView
            } else {
                projectSplitView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            MobileSettingsView()
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .onChange(of: selectedProject) { _, newValue in
            if newValue != nil {
                selectedSession = nil
                showingBriefing = false
                showingTasks = false
            }
        }
    }

    private var briefingSplitView: some View {
        NavigationSplitView {
            projectSidebar
        } content: {
            NavigationStack {
                BriefingListView(selectedGroup: $selectedBriefingGroup)
                    .navigationDestination(for: String.self) { sessionID in
                        MobileChatView(sessionID: sessionID, onClose: {})
                            .id(sessionID)
                            .task(id: sessionID) {
                                if !MobileDraftSessionID.isDraft(sessionID) {
                                    await state.subscribe(to: sessionID)
                                }
                            }
                    }
                    .onChange(of: selectedBriefingGroup) { _, _ in
                        // Clear navigation path when switching briefing groups
                        briefingDetailPath.removeLast(briefingDetailPath.count)
                    }
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

    private var tasksSplitView: some View {
        NavigationSplitView {
            projectSidebar
        } detail: {
            tasksStack
        }
    }

    /// Chats opened from a task push onto the Tasks stack, so Back returns to
    /// the task instead of jumping to the project's thread list.
    private var tasksStack: some View {
        NavigationStack(path: $tasksPath) {
            MobileTasksDashboardView { sessionID in
                tasksPath.append(sessionID)
            }
            .navigationDestination(for: String.self) { sessionID in
                chatDestination(sessionID, onClose: closeTasksChat)
            }
        }
    }

    private func closeTasksChat() {
        if !tasksPath.isEmpty { tasksPath.removeLast() }
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
            if let projectID = selectedProject,
               state.projects.contains(where: { $0.id == projectID }) {
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
        ProjectsSidebar(
            selected: $selectedProject,
            showingBriefing: $showingBriefing,
            showingTasks: $showingTasks
        )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
    }

    private func chatDestination(_ sessionID: String, onClose: (() -> Void)? = nil) -> some View {
        MobileChatView(sessionID: sessionID, onClose: onClose ?? { closeChat() })
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
        if usesPhoneLayout {
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
        if isViewingBriefingDetail || isViewingTasksDetail {
            return
        }
        navigate(toSession: sessionID, projectID: nil)
    }

    /// A task, board, or chat pushed from the Tasks tab. Subscribing to a chat
    /// opened there updates `activeSessionID`, which must not pull the user
    /// over to the Projects tab.
    private var isViewingTasksDetail: Bool {
        let tasksVisible = usesPhoneLayout ? selectedTab == .tasks : showingTasks
        return tasksVisible && !tasksPath.isEmpty
    }

    private var isViewingBriefingDetail: Bool {
        if usesPhoneLayout {
            // iPhone: the path holds [briefingGroupKey, …], so a non-empty
            // path while on the Briefing tab means a detail screen is open.
            return selectedTab == .briefing && !briefingDetailPath.isEmpty
        }
        // iPad: the selected group lives in `selectedBriefingGroup`, not on
        // the path — so the path is empty while sitting on briefing detail
        // and only grows when a thread is pushed. Either signal means the
        // user is inside the briefing flow and a desktop-driven session
        // change must not yank them into the projects column.
        return showingBriefing
            && (selectedBriefingGroup != nil || !briefingDetailPath.isEmpty)
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
        showingTasks = false

        // Resolve the owning project so the navigation stack keeps its
        // Projects → Threads → Chat hierarchy. Draft sessions encode the
        // project in their ID; synced sessions are looked up in `state`.
        let resolvedProjectID = projectID
            ?? state.sessions.first(where: { $0.id == sessionID })?.projectId
            ?? MobileDraftSessionID.projectID(from: sessionID)

        if usesPhoneLayout {
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
