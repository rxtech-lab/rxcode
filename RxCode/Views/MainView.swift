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
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarTab: SidebarTab = .history
    @State private var fileSearchTrigger = false
    @State private var inspectorStarted = false
    @AppStorage(AppStorageKeys.showRightSidebar) private var showRightSidebar = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projectToDelete: Project? = nil
    @State private var projectToRename: Project? = nil
    @State private var renameText: String = ""
    @State private var memoAnchor: Bool = false

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

    private var navigationTitleText: String {
        if windowState.showingBriefing {
            return "Briefing"
        }
        if let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title,
           !title.isEmpty
        {
            return title
        }
        return windowState.selectedProject?.name ?? ""
    }

    var body: some View {
        if !appState.onboardingCompleted {
            OnboardingView()
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
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

                if inspectorStarted {
                    RightInspectorPanel(
                        maxAllowedWidth: RightInspectorPanelLayout.maximumWidth(in: proxy.size.width)
                    )
                }
            }
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
                   windowState.inspectorTab == .terminal {
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
            ToolbarItem(placement: .navigation) {
                Button {
                    showGitHubSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(appState.isSignedIn ? "Import Repository" : "Sign in to rxlab")
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    showFilePicker = true
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
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    windowState.showGlobalSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search Threads (⌘K)")
                .popoverTip(RxCodeTips.GlobalSearchTip(), arrowEdge: .top)
            }

            ToolbarItem(placement: .navigation) {
                ThreadTitlePopoverButton(title: navigationTitleText)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            ProjectTreeView()
        }
        .background(ClaudeTheme.sidebarBackground.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 500)
        .sheet(isPresented: $showGitHubSheet) {
            AutopilotRepoSheet()
        }
    }

    // MARK: - Detail

    @Environment(\.openWindow) private var openWindow

    private var detailContent: some View {
        Group {
            if windowState.showingBriefing {
                BriefingView()
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
                        PermissionQueueBanner()
                    })
                }
                .modifier(ChatDetailModifiers())
            } else if !windowState.isInitialized {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
            } else {
                EmptyProjectStateView()
            }
        }
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

// MARK: - Detail Toolbar (isolated struct — no selectedProject dependency, prevents NSToolbar re-layout on project switch)

struct DetailToolbar: View {
    var body: some View {
        Color.clear
            .toolbar {
                RxCodeToolbarContent()
            }
    }
}

// MARK: - Unified Title Bar

/// Makes the hosting NSWindow's titlebar transparent and lets content extend
/// under it, so sidebar/detail backgrounds reach the top of the window
/// instead of leaving a separate full-width colored title-bar strip.
struct UnifiedTitleBarAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
    }
}

// MARK: - Project Tab Button (isolated — isSelected passed as value, body reads no @Observable properties)

struct ProjectTabButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow

    let project: Project
    let isSelected: Bool
    @Binding var projectToDelete: Project?
    @Binding var projectToRename: Project?
    @Binding var renameText: String

    var body: some View {
        Button {
            appState.selectProject(project, in: windowState)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                Text(project.name)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? ClaudeTheme.accent : ClaudeTheme.surfaceSecondary,
                in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
            )
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            openWindow(id: "project-window", value: ProjectWindowValue(projectId: project.id, instanceId: UUID()))
        }
        .contextMenu {
            Button {
                renameText = project.name
                projectToRename = project
            } label: {
                Label("Rename Project", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                projectToDelete = project
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
    }
}

// MARK: - Inspector Tab Control

struct InspectorTabControl: View {
    @Binding var selection: InspectorTab
    var onTabClick: (InspectorTab) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                    onTabClick(tab)
                } label: {
                    Text(tab.title)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == tab ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                        .background(
                            selection == tab ? ClaudeTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
    }
}

// MARK: - Claude Segmented Control

struct ClaudeSegmentedControl: View {
    @Binding var selection: MainView.SidebarTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainView.SidebarTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        Text(tab.title)
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == tab ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                    .background(
                        selection == tab ? ClaudeTheme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
    }
}

// MARK: - Sidebar Tab Shortcuts

struct SidebarTabShortcuts: View {
    @Binding var sidebarTab: MainView.SidebarTab
    @Binding var fileSearchTrigger: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background {
                Button("") {
                    withAnimation(.easeInOut(duration: 0.15)) { sidebarTab = .files }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fileSearchTrigger.toggle() }
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

                Button("") {
                    columnVisibility = .all
                    withAnimation(.easeInOut(duration: 0.15)) { sidebarTab = .history }
                }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()

                Button("") {
                    columnVisibility = .all
                    withAnimation(.easeInOut(duration: 0.15)) { sidebarTab = .files }
                }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()
            }
    }
}

#Preview {
    MainView()
        .environment(AppState())
        .environment(WindowState())
}
