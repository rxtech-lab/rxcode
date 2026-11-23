import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showGitHubSheet = false
    @State private var showFilePicker = false
    @State private var showCreateWorkspaceSheet = false
    @State private var showManageWorkspaceSheet = false
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarTab: SidebarTab = .history
    @State private var fileSearchTrigger = false
    @State private var inspectorStarted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projectToDelete: Project? = nil
    @State private var projectToRename: Project? = nil
    @State private var renameText: String = ""
    @State private var showAllWhatsNew = false

    // Kept for backward compatibility with `ClaudeSegmentedControl` and `SidebarTabShortcuts`.
    enum SidebarTab: String, CaseIterable {
        case history = "History"
        case files = "Files"

        var title: LocalizedStringResource {
            switch self {
            case .history: "History"
            case .files: "Files"
            }
        }

        var icon: String {
            switch self {
            case .files: "folder"
            case .history: "clock"
            }
        }
    }

    /// Re-runs the new-chat hooks (e.g. the Autopilot `.env` banner) whenever the
    /// open project, repository link, or active session changes, so the banner
    /// appears when opening chat, not only after the first message is sent.
    private var newChatHookKey: String {
        "\(windowState.selectedProject?.id.uuidString ?? "none")|\(windowState.selectedProject?.gitHubRepo ?? "")|\(windowState.currentSessionId ?? "new")"
    }

    /// Re-evaluate the new-chat hooks (e.g. the Autopilot `.env` banner) after the
    /// secrets sheet closes, so finishing a backup immediately dismisses the
    /// "back up secrets" banner instead of waiting for the next chat switch.
    private func rerunNewChatHooks() {
        guard let project = windowState.selectedProject else { return }
        let sessionKey = windowState.currentSessionId ?? windowState.newSessionKey
        Task { await appState.runProjectNewChatHooks(projectId: project.id, sessionKey: sessionKey) }
    }

    private var navigationTitleText: String {
        if let route = windowState.generalRoute {
            return route.displayNameText
        }
        if let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title,
           !title.isEmpty
        {
            return title
        }
        return windowState.selectedProject?.name ?? ""
    }

    private var showRightSidebar: Bool {
        appState.showRightSidebar
    }

    var body: some View {
        if !appState.onboardingCompleted {
            OnboardingView()
        } else {
            mainContent.modifier(WindowRepositoryStatus())
        }
    }

    private var mainContent: some View {
        InspectorWorkspaceLayout(inspectorStarted: inspectorStarted) {
            navigationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(appState.themeRevision)
                .onChange(of: showRightSidebar) { _, isShowing in
                    if isShowing, !inspectorStarted { inspectorStarted = true }
                }
                .onChange(of: appState.focusMode) { _, newValue in
                    windowState.focusMode = newValue
                }
                .onAppear {
                    windowState.focusMode = appState.focusMode
                    // The panel is built lazily; if it was left open in a
                    // previous launch, start it now so it reappears.
                    if showRightSidebar { inspectorStarted = true }
                }
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(UnifiedTitleBarAccessor())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rxcode-main-view")
                .toolbar {
                    toolbarContent
                }
        }
        .hookUI()
        .focusedSceneValue(\.showWhatsNew) {
            showAllWhatsNew = true
        }
        .task(id: appState.isInitialized) {
            guard appState.isInitialized else { return }
            if appState.wasOnboardedAtLaunch {
                // Existing user: surface any feature cards they haven't seen.
                let unseen = appState.unseenWhatsNewFeatures
                if !unseen.isEmpty {
                    appState.whatsNewBatch = unseen
                    appState.showWhatsNewSheet = true
                }
            } else {
                // Brand-new install this session — these features aren't
                // "new" to them, so record them all as seen up front.
                appState.markAllWhatsNewSeen()
            }
        }
        .sheet(isPresented: Bindable(appState).showWhatsNewSheet) {
            WhatsNewSheet(features: appState.whatsNewBatch) {
                appState.showWhatsNewSheet = false
            }
            .environment(appState)
        }
        .sheet(isPresented: $showAllWhatsNew) {
            WhatsNewSheet(features: WhatsNewFeature.all) {
                showAllWhatsNew = false
            }
            .environment(appState)
        }
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
        .background {
            Button("") {
                columnVisibility = (columnVisibility == .all) ? .detailOnly : .all
            }
            .keyboardShortcut("3", modifiers: .command)
            .hidden()
        }
        .overlay {
            marketplaceOverlay
        }
        .overlay {
            globalSearchOverlay
        }
        .background {
            Button("") {
                // Cmd+K is context-sensitive: when the inspector terminal tab
                // is active, clear the terminal; otherwise open global search.
                if showRightSidebar,
                   windowState.inspectorMode == .inspector,
                   windowState.inspectorLayout.tools.selectedTab?.tool == .terminal
                {
                    windowState.clearTerminalRequest = UUID()
                } else {
                    windowState.showGlobalSearch.toggle()
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()
        }
    }

    @ViewBuilder
    private var marketplaceOverlay: some View {
        if windowState.showMarketplace {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            windowState.showMarketplace = false
                        }
                    }
                SkillMarketView()
                    .focusable(false)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
    }

    @ViewBuilder
    private var globalSearchOverlay: some View {
        if windowState.showGlobalSearch {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            windowState.showGlobalSearch = false
                        }
                    }
                GlobalSearchOverlay()
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: windowState.showGlobalSearch)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if columnVisibility != .detailOnly {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Add project locally", systemImage: "folder.badge.plus")
                    }

                    Button {
                        showGitHubSheet = true
                    } label: {
                        Label("Add project from remote repositories", systemImage: "square.and.arrow.down")
                    }

                    Divider()

                    Button {
                        windowState.newProjectPrefersCloud = false
                        windowState.showNewProjectSheet = true
                    } label: {
                        Label("New project…", systemImage: "plus.rectangle.on.folder")
                    }

                    Button {
                        windowState.newProjectPrefersCloud = true
                        windowState.showNewProjectSheet = true
                    } label: {
                        Label("New cloud project…", systemImage: "icloud")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Project")
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    handleFolderSelection(result)
                }

                Button {
                    windowState.showGlobalSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help(String(localized: "Search Threads and Docs (⌘K)"))
                .accessibilityIdentifier("toolbar-global-search")
                .popoverTip(RxCodeTips.GlobalSearchTip(), arrowEdge: .top)
            }

            ToolbarItem(placement: .navigation) {
                ThreadTitlePopoverButton(title: navigationTitleText)
                    .accessibilityIdentifier("toolbar-navigation-title")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            ProjectTreeView()
        }
        .background(ClaudeTheme.sidebarBackground.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 500)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                WorkspaceSwitcher(
                    showingCreateSheet: $showCreateWorkspaceSheet,
                    showingManageSheet: $showManageWorkspaceSheet
                )
            }
        }
        .sheet(isPresented: $showCreateWorkspaceSheet) {
            CreateWorkspaceSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showManageWorkspaceSheet) {
            ManageWorkspacesSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showGitHubSheet) {
            AutopilotRepoSheet()
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
    }

    // MARK: - Detail

    @Environment(\.openWindow) private var openWindow

    private var detailContent: some View {
        Group {
            if windowState.showingTasks {
                TaskBoardView()
            } else if windowState.showingBriefing {
                BriefingView()
            } else if windowState.generalRoute == .chat {
                GlobalChatView()
            } else if windowState.generalRoute == .scheduled {
                ScheduledTasksView()
            } else if windowState.selectedProject != nil {
                VStack(spacing: 0) {
                    ChatView(inputAccessory: {
                        HStack(spacing: 8) {
                            ChatToolbarControls(placement: .composer)
                            BranchPickerChip()
                        }
                    }, bottomAccessory: {
                        RecentChatsSuggestionList()
                    }, aboveInputAccessory: {
                        VStack(spacing: 8) {
                            AgentConfirmationBanner()
                            PermissionQueueBanner()
                            ComputerUsePreviewBanner()
                            ThreadDiffBanner()
                            HookBannerHost(surface: .newProject, position: .aboveInputBox)
                        }
                    })
                }
                .modifier(ChatDetailModifiers())
                .task(id: newChatHookKey) {
                    guard let project = windowState.selectedProject else { return }
                    await appState.runProjectNewChatHooks(
                        projectId: project.id,
                        sessionKey: windowState.currentSessionId ?? windowState.newSessionKey
                    )
                }
            } else if !windowState.isInitialized {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
            } else {
                EmptyProjectStateView()
            }
        }
        .reportsInspectorDetailWidth(to: windowState)
        .fileInspectorSheet(windowState)
        .sheet(item: Bindable(appState).localModelSheetRequest) { request in
            LocalModelsSheet(initialModel: request)
                .localModelsSheetFrame()
                .environment(appState)
        }
        .sheet(item: Bindable(appState).secretsSetupRequest, onDismiss: rerunNewChatHooks) { request in
            SecretsManageSheet(
                currentRepoFullName: request.repoFullName,
                currentProjectPath: request.projectPath
            )
            .environment(appState)
        }
        .sheet(item: Bindable(appState).secretsDownloadRequest) { project in
            SecretsDownloadSheet(project: project)
                .environment(appState)
        }
        .sheet(item: Bindable(appState).ciSetupRequest, onDismiss: rerunNewChatHooks) { request in
            CIUpdateManageSheet(
                currentRepoFullName: request.repoFullName,
                currentProjectPath: request.projectPath
            )
            .environment(appState)
        }
        .sheet(item: Bindable(appState).userGuideRequest) { request in
            UserManualView(initialSection: request.section)
        }
        .onChange(of: appState.docsSearchRequest) { _, request in
            guard request != nil else { return }
            windowState.showGlobalSearch = true
            appState.docsSearchRequest = nil
        }
        .onChange(of: appState.docsSetupRequest?.id) { _, _ in
            guard let request = appState.docsSetupRequest else { return }
            // The setup hook asks the new chat to load the docs-publishing skill.
            if let projectId = request.projectId,
               let project = appState.projects.first(where: { $0.id == projectId }),
               windowState.selectedProject?.id != projectId
            {
                appState.selectProject(project, in: windowState)
            }
            appState.pendingDocsSetupProjectId = request.projectId ?? windowState.selectedProject?.id
            appState.startNewChat(in: windowState)
            let repoText = request.repoFullName.map { " for \($0)" } ?? ""
            let prompt = "Set up documentation publishing\(repoText) by following the docs-publishing skill: inspect the repo, author the docs under docs/, add the uploader script and CI workflow, and tell me exactly what DOCS_UPLOAD_TOKEN to set."
            appState.docsSetupRequest = nil
            // Send the prompt straight to the agent — mirror the IDE `send_to_thread`
            // new-thread flow (AppState.sendCrossProject), which calls sendPrompt
            // directly rather than routing through the composer's inputText. Going
            // through inputText lets the composer auto-collapse the long text into
            // an attachment thumbnail before it's sent.
            Task { await appState.sendPrompt(prompt, in: windowState) }
        }
        .onChange(of: appState.releaseSetupRequest?.id) { _, _ in
            guard let request = appState.releaseSetupRequest else { return }
            // The setup hook asks the new chat to load the release skill.
            if let projectId = request.projectId,
               let project = appState.projects.first(where: { $0.id == projectId }),
               windowState.selectedProject?.id != projectId
            {
                appState.selectProject(project, in: windowState)
            }
            appState.pendingReleaseSetupProjectId = request.projectId ?? windowState.selectedProject?.id
            appState.startNewChat(in: windowState)
            let repoText = request.repoFullName.map { " for \($0)" } ?? ""
            let prompt = "Set up release publishing\(repoText) by following the create-release skill: inspect the repo, create the `.releaserc` and the release CI workflow (ask me whether to trigger releases on branch push or manually), then register the repo and install the RELEASE_TOKEN via the `ide__setup_release` tool."
            appState.releaseSetupRequest = nil
            Task { await appState.sendPrompt(prompt, in: windowState) }
        }
        // The sheet settles its own proposal, so the setter has nothing to do.
        .sheet(item: Binding(
            get: { appState.scheduledTaskProposals.first },
            set: { _ in }
        )) { proposal in
            ScheduledTaskFormSheet(task: proposal, isNew: true) { task in
                appState.resolveScheduledTaskProposal(id: proposal.id, with: task)
            }
            .environment(appState)
        }
        .sheet(item: Bindable(appState).releaseCreateRequest) { project in
            ReleaseCreateSheet(
                repoId: project.gitHubRepo ?? "",
                repoFullName: project.gitHubRepo ?? project.name,
                currentVersion: appState.projectLatestReleaseVersion(project),
                projectPath: project.path
            )
            .environment(appState)
        }
        .sheet(item: Bindable(windowState).diffFile) { file in
            FileDiffView(
                filePath: file.path,
                fileName: file.name,
                editHunks: file.editHunks,
                gitDiffMode: file.gitDiffMode,
                showFullFileDiff: file.showFullFileDiff,
                originalContent: file.originalContent,
                modifiedContent: file.modifiedContent,
                preferHunks: file.preferHunks
            )
            .frame(minWidth: 1000, idealWidth: 1400, maxWidth: 1920,
                   minHeight: 600, idealHeight: 1000, maxHeight: 1200)
        }
        .sheet(isPresented: Bindable(windowState).showRunConfigurations) {
            if let project = windowState.selectedProject {
                RunConfigurationsView(project: project)
                    .environment(appState)
                    .environment(windowState)
            }
        }
        .alert("Error", isPresented: Bindable(windowState).showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(windowState.errorMessage ?? ""))
        }
        .focusedValue(\.startNewChat) {
            appState.startNewChat(in: windowState)
        }
        // Toolbar is in an isolated struct so NSToolbar does not re-layout on project switches.
        .background {
            DetailToolbar()
        }
    }

    // MARK: - Folder Selection

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await appState.addProjectFromFolder(url, in: windowState) }
    }
}

#Preview {
    MainView()
        .environment(WorkspaceBrowser())
        .environment(WorkspaceDesignSession())
        .environment(AppState())
        .environment(WindowState())
}
