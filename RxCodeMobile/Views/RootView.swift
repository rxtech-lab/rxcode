import os.log
import RxCodeCore
import RxCodeSync
import SwiftUI

private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "RootView")

private enum MobileRootTab: Hashable {
    case briefing
    case projects
    case settings
    case search
}

/// Mobile app root. iPad / wide screens use NavigationSplitView; iPhone uses
/// bottom navigation with independent NavigationStack tabs. An open iPhone Duo
/// keeps the tabs and shows threads and the chat side by side in Projects.
struct RemoteWorkspaceView: View {
    @Environment(\.closeRemoteWorkspace) private var closeRemoteWorkspace
    @Environment(MobileCloudState.self) private var cloud
    @State private var showOfflineTasksSheet = false
    @State private var showOfflineTasksFullScreen = false
    @Environment(\.horizontalSizeClass) private var compactClass
    @Environment(\.verticalSizeClass) private var verticalClass
    @EnvironmentObject private var state: MobileAppState
    @State private var selectedProject: UUID?
    @State private var selectedSession: String?
    @State private var selectedBriefingGroup: BriefingGroupKey?
    @State private var briefingDetailPath = NavigationPath()
    @State private var showingBriefing = false
    @State private var showSettings = false
    @State private var showingTasks = true
    @State private var selectedTab: MobileRootTab = .briefing
    /// [project, chat] on a compact iPhone. On an open Duo only the project,
    /// since the chat is `selectedSession` in the detail column.
    @State private var projectsPath = NavigationPath()
    @State private var isDuoSidebarVisible = true
    /// Owned here (not by the stack) so the Tasks navigation survives layout
    /// changes, and so chats opened from a task push onto it.
    @State private var tasksPath = NavigationPath()
    @State private var minimumLoadingTimeElapsed = false
    @State private var connectionTimedOut = false
    /// Set once the workspace has been shown for the current desktop. From then
    /// on a transient relay drop must not unmount it: tearing the whole tree
    /// down dismissed the keyboard, wiped the composer, re-subscribed the open
    /// thread and re-rendered everything on each flap. A small overlay reports
    /// the reconnect instead. Reset when the desktop mirror is cleared.
    @State private var hasShownWorkspace = false
    /// Shown only after the connection has been down for a moment, so a brief
    /// socket hiccup doesn't flash the reconnect overlay.
    @State private var showReconnectOverlay = false

    var body: some View {
        Group {
            // Signing in is required before pairing. UI-test launches drive
            // pairing against a mock relay without an account.
            if UITestSupport.isActive || cloud.isSignedIn {
                if state.isPaired {
                    paired
                } else {
                    NavigationStack {
                        OnboardingView(onViewTasks: openOfflineTasks)
                            .toolbar { RemoteWorkspaceCloseToolbar() }
                    }
                }
            } else if cloud.isRestoring {
                MobileRestoringSessionView()
            } else {
                MobileSignInView()
            }
        }
        .animation(.smooth(duration: 0.3), value: cloud.isSignedIn)
        .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
            // Feature services post this too; sign out only once RxAuth itself
            // has rejected the session, never for a transient token failure.
            guard !cloud.auth.isAuthenticated else { return }
            Task { await cloud.signOut(requiresPushRemoval: false) }
        }
        .onChange(of: cloud.isSignedIn) { _, signedIn in
            if !signedIn {
                state.clearCloudTasks()
                showOfflineTasksSheet = false
                showOfflineTasksFullScreen = false
            }
        }
        .sheet(isPresented: $showOfflineTasksSheet, onDismiss: { state.usesCloudTasks = false }) {
            offlineTasks
                .mobileSheetPresentation([.large])
        }
        .fullScreenCover(isPresented: $showOfflineTasksFullScreen, onDismiss: { state.usesCloudTasks = false }) {
            offlineTasks
        }
        .sheet(item: $state.pendingPermission) { req in
            PermissionApprovalSheet(request: req)
                .environmentObject(state)
        }
        .mobileDismissesKeyboardOnScroll()
    }

    private func openOfflineTasks() {
        if state.isDesktopTaskSyncReady {
            selectedTab = .projects
            showingTasks = true
            return
        }
        state.usesCloudTasks = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            showOfflineTasksFullScreen = true
        } else {
            showOfflineTasksSheet = true
        }
    }

    private var offlineTasks: some View {
        NavigationStack {
            MobileTasksDashboardView(onOpenChat: { _ in })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showOfflineTasksSheet = false
                            showOfflineTasksFullScreen = false
                        }
                    }
                }
        }
        .environmentObject(state)
        .environment(cloud)
    }

    /// Whether the loading splash should be dismissed (data loaded AND minimum time elapsed, but NOT timed out)
    private var shouldShowContent: Bool {
        hasShownWorkspace || isInitialSyncComplete
    }

    private var isInitialSyncComplete: Bool {
        state.isDesktopTaskSyncReady && minimumLoadingTimeElapsed && !connectionTimedOut
    }

    private var paired: some View {
        ZStack {
            // Mount the desktop workspace only when it is reachable. Hidden
            // task views must not issue requests or present alerts behind the cloud sheet.
            if shouldShowContent {
                mainContent
                    .overlay(alignment: .top) {
                        if showReconnectOverlay {
                            MobileReconnectOverlay(
                                desktopName: state.activePairedDesktop?.displayName,
                                isUnavailable: state.desktopTaskUnavailable,
                                isRetrying: isRetryingConnection,
                                onRetry: {
                                    MobileHaptics.buttonTap()
                                    Task { await retryConnection() }
                                }
                            )
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3), value: showReconnectOverlay)
            }

            // Loading splash - shown until first snapshot AND minimum 2 seconds
            if !shouldShowContent {
                SyncLoadingView(
                    isTimedOut: !isRetryingConnection && (connectionTimedOut || state.desktopTaskUnavailable),
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
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if let closeRemoteWorkspace {
                        Button {
                            MobileHaptics.buttonTap()
                            closeRemoteWorkspace()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Close")
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .buttonBorderShape(.circle)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding()
                    }
                }
                .transition(.splashTransition)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: shouldShowContent)
        .task {
            await initialLoad()
        }
        .onChange(of: state.isDesktopTaskSyncReady) { _, ready in
            logger.info("Desktop sync ready changed: \(ready, privacy: .public) hasShownWorkspace=\(hasShownWorkspace, privacy: .public) connection=\(String(describing: state.connectionState), privacy: .public) unavailable=\(state.desktopTaskUnavailable, privacy: .public)")
            if ready {
                connectionTimedOut = false
            }
        }
        .onChange(of: isInitialSyncComplete) { _, complete in
            if complete, !hasShownWorkspace {
                logger.info("Workspace shown; later reconnects keep it mounted")
                hasShownWorkspace = true
            }
        }
        .task(id: hasShownWorkspace && !state.isDesktopTaskSyncReady) {
            guard hasShownWorkspace, !state.isDesktopTaskSyncReady else {
                if showReconnectOverlay {
                    logger.info("Reconnect overlay hidden")
                }
                showReconnectOverlay = false
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            logger.info("Reconnect overlay shown connection=\(String(describing: state.connectionState), privacy: .public) unavailable=\(state.desktopTaskUnavailable, privacy: .public)")
            showReconnectOverlay = true
        }
        .onChange(of: state.activeSessionID) { oldValue, newValue in
            // Subscribing acknowledges an existing navigation; only an ID
            // replacement needs to change the destination again.
            guard let oldValue, let newValue,
                  MobileDraftSessionID.isDraft(oldValue)
                    || state.resolveSessionID(oldValue) == newValue else { return }
            openActiveSession(newValue)
        }
        .onChange(of: state.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        .onChange(of: state.hasReceivedInitialSnapshot) { oldValue, newValue in
            // Reset states when snapshot state resets (e.g., switching paired desktops)
            if oldValue && !newValue {
                logger.info("Desktop mirror cleared; showing sync splash again")
                hasShownWorkspace = false
                showReconnectOverlay = false
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

        let clock = ContinuousClock()
        let minimumLoadingDeadline = clock.now.advanced(by: .seconds(2))

        // Send the snapshot request (returns immediately, snapshot arrives async)
        consumePendingDeepLink()
        if !state.isDesktopTaskSyncReady {
            await state.refreshSnapshot()
        }

        // Wait for either snapshot to arrive or timeout
        let timeoutSeconds = 15
        let pollIntervalMs: UInt64 = 100
        let maxPolls = (timeoutSeconds * 1000) / Int(pollIntervalMs)

        var pollCount = 0
        while !state.isDesktopTaskSyncReady && pollCount < maxPolls {
            do { try await Task.sleep(for: .milliseconds(pollIntervalMs)) }
            catch { return }
            pollCount += 1
            if pollCount % 50 == 0 { // Log every 5 seconds
                logger.debug("Still waiting for snapshot... polls=\(pollCount)/\(maxPolls)")
            }
        }

        // Count sync work toward the minimum splash duration. Fast or cached
        // connections still show the loading screen for at least two seconds.
        do { try await clock.sleep(until: minimumLoadingDeadline) }
        catch { return }

        let hasSnapshot = state.isDesktopTaskSyncReady
        logger.info("Wait completed: hasSnapshot=\(hasSnapshot), polls=\(pollCount)/\(maxPolls)")

        guard !Task.isCancelled else { return }
        logger.debug("PERFORMANCE: mobile initial sync wait polls=\(pollCount, privacy: .public) ready=\(hasSnapshot, privacy: .public)")

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

    @State private var isRetryingConnection = false

    /// Retry connection after timeout.
    private func retryConnection() async {
        guard !isRetryingConnection else { return }
        isRetryingConnection = true
        defer { isRetryingConnection = false }
        logger.info("Retry connection requested")
        connectionTimedOut = false
        minimumLoadingTimeElapsed = false
        await state.reconnectToDesktop()
        await initialLoad()
    }

    private var mainContent: some View {
        Group {
            if usesPhoneLayout {
                phoneTabs
                    .onChange(of: usesDuoColumns) { _, usesColumns in
                        moveProjectsNavigation(toDuoColumns: usesColumns)
                    }
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

    /// An open iPhone Duo is regular in both directions. A large iPhone in
    /// landscape is regular wide but compact tall, so it stays in the stack.
    private var usesDuoColumns: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && compactClass == .regular
            && verticalClass == .regular
    }

    private var phoneTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Briefing", systemImage: "doc.text", value: MobileRootTab.briefing) {
                NavigationStack(path: $briefingDetailPath) {
                    MobileBriefingView(
                        onCloseChat: { closeBriefingChat() },
                        onOpenSession: { briefingDetailPath.append($0) }
                    )
                    .toolbar { RemoteWorkspaceCloseToolbar() }
                }
            }

            Tab("Projects", systemImage: "folder", value: MobileRootTab.projects) {
                if usesDuoColumns {
                    duoProjectsSplitView
                } else {
                    phoneProjectsStack
                }
            }

            Tab("Settings", systemImage: "gear", value: MobileRootTab.settings) {
                MobileSettingsView(showsDoneButton: false)
            }

            if #available(iOS 27.0, *) {
                Tab("Search", systemImage: "magnifyingglass", value: MobileRootTab.search, role: .prominent) {
                    searchContent
                }
            } else {
                Tab(value: MobileRootTab.search, role: .search) {
                    searchContent
                }
            }
        }
    }

    private var phoneProjects: some View {
        ProjectsSidebar(
            selected: $selectedProject,
            showingBriefing: $showingBriefing,
            showsBriefingItem: false,
            onOpenProject: { projectID in
                selectedProject = projectID
                projectsPath.append(projectID)
            }
        )
    }

    private var phoneProjectsStack: some View {
        NavigationStack(path: $projectsPath) {
            phoneProjects
                .toolbar { RemoteWorkspaceCloseToolbar() }
                .navigationDestination(for: UUID.self) { projectID in
                    SessionsList(
                        projectID: projectID,
                        selected: $selectedSession,
                        usesSelection: false,
                        onOpenThread: { sessionID in
                            selectedSession = sessionID
                            projectsPath.append(sessionID)
                        }
                    )
                    .toolbar { RemoteWorkspaceCloseToolbar(regularWidthOnly: true) }
                }
                .navigationDestination(for: String.self) { sessionID in
                    chatDestination(sessionID)
                }
        }
    }

    /// Projects and threads in a collapsible sidebar, with the chat beside them.
    /// Laid out directly because `NavigationSplitView` overlays its sidebar on a
    /// screen this narrow instead of placing the columns side by side. The close
    /// button lives in the detail column, which is always on screen.
    private var duoProjectsSplitView: some View {
        HStack(spacing: 0) {
            if isDuoSidebarVisible {
                NavigationStack(path: $projectsPath) {
                    // The tab rail's inset belongs to the far edge of the chat column.
                    phoneProjects
                        .ignoresSafeArea(.container, edges: .trailing)
                        .navigationDestination(for: UUID.self) { projectID in
                            SessionsList(projectID: projectID, selected: $selectedSession)
                                .ignoresSafeArea(.container, edges: .trailing)
                        }
                        // Thread search results push instead of selecting.
                        .navigationDestination(for: String.self) { sessionID in
                            chatDestination(sessionID)
                        }
                }
                .containerRelativeFrame(.horizontal) { width, _ in min(280, width * 0.45) }
                .transition(.move(edge: .leading))

                Divider()
                    .ignoresSafeArea()
            }

            NavigationStack {
                Group {
                    if let sessionID = selectedSession {
                        chatDestination(sessionID)
                    } else {
                        ContentUnavailableView(
                            "Select a Thread",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Choose a thread from the sidebar to open its chat.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar { RemoteWorkspaceCloseToolbar() }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(
                            isDuoSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                            systemImage: "sidebar.left"
                        ) {
                            MobileHaptics.buttonTap()
                            withAnimation(.snappy) { isDuoSidebarVisible.toggle() }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("duo-sidebar-toggle")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Carries the open project and chat across folding and unfolding a Duo.
    private func moveProjectsNavigation(toDuoColumns usesColumns: Bool) {
        if usesColumns {
            if projectsPath.count > 1 {
                projectsPath.removeLast(projectsPath.count - 1)
            } else {
                // The stack popped back past the chat, so nothing is open.
                selectedSession = nil
            }
        } else if let selectedSession {
            projectsPath = phoneProjectsPath(toSession: selectedSession, projectID: nil)
        }
    }

    /// Projects → Threads → Chat, so back returns to the thread list.
    private func phoneProjectsPath(toSession sessionID: String, projectID: UUID?) -> NavigationPath {
        var path = NavigationPath()
        if let projectID = resolvedProjectID(forSession: sessionID, projectID: projectID) {
            path.append(projectID)
        }
        path.append(sessionID)
        return path
    }

    /// Draft sessions encode the project in their ID; synced sessions are looked
    /// up in `state`.
    private func resolvedProjectID(forSession sessionID: String, projectID: UUID?) -> UUID? {
        projectID
            ?? state.sessions.first(where: { $0.id == sessionID })?.projectId
            ?? MobileDraftSessionID.projectID(from: sessionID)
    }

    private var searchContent: some View {
        NavigationStack {
            MobileSearchContentView(searchText: $searchText)
                .navigationTitle("Search")
                .toolbar { RemoteWorkspaceCloseToolbar() }
        }
        .searchable(text: $searchText, prompt: "Search threads and docs")
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
                .toolbar { RemoteWorkspaceCloseToolbar() }
                .navigationDestination(for: String.self) { sessionID in
                    MobileChatView(sessionID: sessionID, onClose: { closeBriefingChat() })
                        .id(sessionID)
                        .toolbar { RemoteWorkspaceCloseToolbar() }
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
            .toolbar { RemoteWorkspaceCloseToolbar() }
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
                    .toolbar { RemoteWorkspaceCloseToolbar() }
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
                    .accessibilityIdentifier("open-settings")
                }
            }
    }

    private func chatDestination(_ sessionID: String, onClose: (() -> Void)? = nil) -> some View {
        MobileChatView(sessionID: sessionID, onClose: onClose ?? { closeChat() })
            .id(sessionID)
            // The detail column of an open Duo keeps the tabs reachable.
            .toolbar(usesDuoColumns ? .automatic : .hidden, for: .tabBar)
            .toolbar { RemoteWorkspaceCloseToolbar(regularWidthOnly: true) }
    }

    /// Pop the chat view after its thread is archived or deleted. Compact mode
    /// is driven by `projectsPath`; the split view by `selectedSession`.
    private func closeChat() {
        if usesDuoColumns {
            selectedSession = nil
        } else if usesPhoneLayout {
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

    /// A task, board, or chat pushed from the iPad Tasks sidebar. Subscribing to a chat
    /// opened there updates `activeSessionID`, which must not pull the user
    /// over to the Projects tab.
    private var isViewingTasksDetail: Bool {
        let tasksVisible = !usesPhoneLayout && showingTasks
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
    /// Compact mode shows the chat from `projectsPath` while the split views
    /// show it from `selectedSession`, so only one of them ever presents it.
    private func navigate(toSession sessionID: String, projectID: UUID?) {
        selectedTab = .projects
        showingBriefing = false
        showingTasks = false

        let resolvedProjectID = resolvedProjectID(forSession: sessionID, projectID: projectID)

        if usesDuoColumns {
            selectedSession = sessionID
            guard let resolvedProjectID else { return }
            selectedProject = resolvedProjectID
            var path = NavigationPath()
            path.append(resolvedProjectID)
            if projectsPath != path {
                projectsPath = path
            }
        } else if usesPhoneLayout {
            selectedSession = sessionID
            let path = phoneProjectsPath(toSession: sessionID, projectID: resolvedProjectID)
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

extension EnvironmentValues {
    @Entry var closeRemoteWorkspace: (@MainActor () -> Void)?
}

struct RemoteWorkspaceCloseToolbar: ToolbarContent {
    /// Pushed screens keep the button on open Duo and iPad, where the workspace
    /// has room for it. Compact iPhones close from the root of each tab.
    var regularWidthOnly = false
    @Environment(\.closeRemoteWorkspace) private var closeRemoteWorkspace
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some ToolbarContent {
        if let closeRemoteWorkspace, !regularWidthOnly || sizeClass != .compact {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close", systemImage: "xmark") {
                    MobileHaptics.buttonTap()
                    closeRemoteWorkspace()
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("close-remote-workspace")
            }
        }
    }
}
