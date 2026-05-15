import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projectToDelete: Project? = nil
    @State private var projectToRename: Project? = nil
    @State private var renameText: String = ""
    @State private var memoAnchor: Bool = false

    // Kept for backward compatibility with `ClaudeSegmentedControl` and `SidebarTabShortcuts`.
    enum SidebarTab: String, CaseIterable {
        case history = "History"
        case files = "Files"

        var icon: String {
            switch self {
            case .files: "folder"
            case .history: "clock"
            }
        }
    }

    private var navigationTitleText: String {
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
            HSplitView {
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
                .id(appState.themeRevision)
                .onChange(of: windowState.showInspector) { _, isShowing in
                    if isShowing, !inspectorStarted { inspectorStarted = true }
                }
                .onChange(of: appState.focusMode) { _, newValue in
                    windowState.focusMode = newValue
                }
                .onAppear {
                    windowState.focusMode = appState.focusMode
                }
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(UnifiedTitleBarAccessor())
                .toolbar {
                    if columnVisibility != .detailOnly {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                showGitHubSheet = true
                            } label: {
                                Image("GitHubMark")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                            }
                            .help(appState.isLoggedIn ? "Manage GitHub Repos" : "Connect GitHub")
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
                            Text(navigationTitleText)
                                .padding(.trailing)
                        }
                    }
                }

                if inspectorStarted {
                    RightInspectorPanel()
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            ProjectTreeView()
        }
        .background(ClaudeTheme.sidebarBackground.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        .sheet(isPresented: $showGitHubSheet) {
            GitHubSheet()
        }
    }

    // MARK: - Detail

    @Environment(\.openWindow) private var openWindow

    private var detailContent: some View {
        Group {
            if windowState.selectedProject != nil {
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
                VStack(spacing: 16) {
                    Image(systemName: "sparkle")
                        .font(.system(size: ClaudeTheme.size(48)))
                        .foregroundStyle(ClaudeTheme.accent)

                    Text("Select a Project")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    Text("Select a project from the sidebar or add a new one.")
                        .font(.subheadline)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClaudeTheme.background)
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
                gitDiffMode: file.gitDiffMode
            )
            .frame(minWidth: 1000, idealWidth: 1400, maxWidth: 1920,
                   minHeight: 600, idealHeight: 1000, maxHeight: 1200)
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
                    Text(LocalizedStringKey(tab.rawValue))
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
                        Text(LocalizedStringKey(tab.rawValue))
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

// MARK: - Shared Chat UI Components

private func effortDisplayName(_ effort: String) -> String {
    switch effort {
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "XHigh"
    case "max": return "Max"
    default: return effort.capitalized
    }
}

enum ChatToolbarControlsPlacement {
    case toolbar
    case composer
}

struct ChatToolbarControls: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let placement: ChatToolbarControlsPlacement

    init(placement: ChatToolbarControlsPlacement = .toolbar) {
        self.placement = placement
    }

    private var effectiveMode: PermissionMode { windowState.sessionPermissionMode ?? appState.permissionMode }
    private var effectiveModel: String { appState.effectiveModelSelection(in: windowState).model }
    private var effectiveProvider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }

    var body: some View {
        HStack(spacing: placement == .composer ? 8 : 4) {
            if placement == .composer {
                Spacer(minLength: 12)
            }

            Menu {
                Section("Permission Mode") {
                    ForEach(PermissionMode.allCases.filter { $0 != .plan }, id: \.self) { mode in
                        Button {
                            appState.setSessionPermissionMode(mode, in: windowState)
                        } label: {
                            Text(LocalizedStringKey(mode.displayName))
                            if effectiveMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: effectiveMode.displayName,
                    icon: nil,
                    isAccent: placement == .composer,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode: \(effectiveMode.displayName)")

            Menu {
                Section("Model Picker") {
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section {
                            ForEach(section.models, id: \.key) { model in
                                Button {
                                    appState.setSessionModel(model.id, provider: model.provider, in: windowState)
                                } label: {
                                    let isSelected = effectiveProvider == model.provider && effectiveModel == model.id
                                    if let iconURL = section.iconURL {
                                        Label {
                                            Text(isSelected ? "\(model.displayName) ✓" : model.displayName)
                                        } icon: {
                                            ACPIconView(url: iconURL, size: 14)
                                        }
                                    } else {
                                        Text(isSelected ? "\(model.displayName) ✓" : model.displayName)
                                    }
                                }
                            }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: "\(effectiveProvider == .codex ? "Codex · " : "")\(appState.modelDisplayLabel(effectiveModel, provider: effectiveProvider))",
                    icon: nil,
                    isAccent: false,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model: \(effectiveProvider.displayName) · \(appState.modelDisplayLabel(effectiveModel, provider: effectiveProvider))")

            Menu {
                Section("Effort Picker") {
                    Button {
                        appState.setSessionEffort(nil, in: windowState)
                    } label: {
                        Text("Auto Effort")
                        if windowState.sessionEffort == nil { Image(systemName: "checkmark") }
                    }
                    Divider()
                    ForEach(AppState.availableEfforts, id: \.self) { effort in
                        Button {
                            appState.setSessionEffort(effort, in: windowState)
                        } label: {
                            Text(LocalizedStringKey(effortDisplayName(effort)))
                            if windowState.sessionEffort == effort { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: windowState.sessionEffort.map { effortDisplayName($0) } ?? "Auto Effort",
                    icon: nil,
                    isAccent: false,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Effort level: \(windowState.sessionEffort.map { effortDisplayName($0) } ?? "Auto Effort")")
        }
        .frame(maxWidth: placement == .composer ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private func controlLabel(title: String, icon: String?, isAccent: Bool, isActive: Bool) -> some View {
        switch placement {
        case .toolbar:
            ToolbarChipLabel(title: title, icon: icon, isActive: isActive)
        case .composer:
            ComposerControlLabel(title: title, icon: icon, isAccent: isAccent, isActive: isActive)
        }
    }
}

struct ToolbarChipLabel: View {
    let title: String
    var icon: String? = nil
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
        }
        .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isActive
                ? ClaudeTheme.accent.opacity(isHovered ? 0.18 : 0.12)
                : (isHovered ? ClaudeTheme.surfaceTertiary : ClaudeTheme.surfaceSecondary),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(
                    isActive ? ClaudeTheme.accent.opacity(0.45) : ClaudeTheme.borderSubtle,
                    lineWidth: isActive ? 1 : 0.5
                )
        )
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

struct ComposerControlLabel: View {
    let title: String
    var icon: String? = nil
    let isAccent: Bool
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle((isAccent || isActive) ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isActive
                ? ClaudeTheme.accent.opacity(isHovered ? 0.18 : 0.12)
                : (isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.85) : Color.clear),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(
                    isActive ? ClaudeTheme.accent.opacity(0.45) : Color.clear,
                    lineWidth: isActive ? 1 : 0
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

struct ChatDetailModifiers: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    private var presentedRequest: PermissionRequest? {
        guard let id = windowState.presentedPermissionId else { return nil }
        return windowState.pendingPermissions.first {
            $0.id == id && $0.sessionId == windowState.currentSessionId
        }
    }

    private var presentedPermissionModalRequest: PermissionRequest? {
        guard let request = presentedRequest, request.toolName != "AskUserQuestion" else { return nil }
        return request
    }

    private var questionSheetBinding: Binding<Bool> {
        Binding(
            get: { presentedRequest?.toolName == "AskUserQuestion" },
            set: { isPresented in
                if !isPresented, presentedRequest?.toolName == "AskUserQuestion" {
                    windowState.presentedPermissionId = nil
                }
            }
        )
    }

    private var presentedPlan: PendingPlan? {
        guard let id = windowState.presentedPlanToolCallId else { return nil }
        return chatBridge.pendingPlans.first { $0.toolCallId == id }
    }

    private var planSheetBinding: Binding<Bool> {
        Binding(
            get: { presentedPlan != nil },
            set: { isPresented in
                if !isPresented {
                    windowState.presentedPlanToolCallId = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowState.pendingPermissions.count)
            .overlay {
                if let request = presentedPermissionModalRequest {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                            .onTapGesture { windowState.presentedPermissionId = nil }
                        PermissionModal(request: request, onClose: { windowState.presentedPermissionId = nil })
                            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
                            .shadow(color: ClaudeTheme.shadowColor, radius: 20)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowState.presentedPermissionId)
                }
            }
            .sheet(isPresented: questionSheetBinding) {
                if let request = presentedRequest, request.toolName == "AskUserQuestion" {
                    QuestionSheetView(
                        request: request,
                        remainingCount: max(0, windowState.pendingPermissions.count - 1),
                        onSubmit: { answers in
                            windowState.submitQuestionAnswersHandler?(request.id, answers)
                        },
                        onClose: {
                            // Just dismiss — keep the request in the queue so the user
                            // can re-open it from the banner later.
                            windowState.presentedPermissionId = nil
                        },
                        onSkipAll: {
                            windowState.skipQuestionHandler?(request.id)
                        }
                    )
                    .environment(appState)
                    .environment(windowState)
                }
            }
            .onChange(of: windowState.pendingPermissions.map(\.id)) { _, newIds in
                if let id = windowState.presentedPermissionId, !newIds.contains(id) {
                    windowState.presentedPermissionId = nil
                }
            }
            .sheet(isPresented: planSheetBinding) {
                if let plan = presentedPlan {
                    PlanSheetView(
                        plan: plan,
                        remainingCount: max(0, chatBridge.pendingPlans.filter { !$0.isDecided }.count - 1),
                        onSubmit: { toolCallId, action in
                            windowState.planDecisionHandler?(toolCallId, action)
                            // Decision recorded — close the sheet. The chip in chat
                            // will reflect the new status once the result lands.
                            windowState.presentedPlanToolCallId = nil
                        },
                        onClose: {
                            // Just dismiss — the plan stays in the queue so the user
                            // can re-open it from the banner or inline chip later.
                            windowState.presentedPlanToolCallId = nil
                        }
                    )
                    .environment(appState)
                    .environment(windowState)
                    .environment(chatBridge)
                }
            }
            .onChange(of: chatBridge.pendingPlans.map(\.toolCallId)) { _, newIds in
                if let id = windowState.presentedPlanToolCallId, !newIds.contains(id) {
                    windowState.presentedPlanToolCallId = nil
                }
            }
            .sheet(isPresented: Bindable(windowState).showModelPicker) {
                ModelPickerSheet()
                    .environment(appState)
                    .environment(windowState)
            }
            .sheet(isPresented: Bindable(windowState).showEffortPicker) {
                EffortPickerSheet()
                    .environment(appState)
                    .environment(windowState)
            }
            .sheet(item: Bindable(windowState).interactiveTerminal) { terminal in
                InteractiveTerminalPopup(state: terminal)
            }
            .sheet(isPresented: Bindable(windowState).showRunConfigurations) {
                if let project = windowState.selectedProject {
                    RunConfigurationsView(project: project)
                        .environment(appState)
                        .environment(windowState)
                }
            }
    }
}

// MARK: - Model Picker Sheet

struct ModelPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var effectiveModel: String { appState.effectiveModelSelection(in: windowState).model }
    private var effectiveProvider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }
    private var flatModels: [AgentModel] { appState.availableAgentModelSections().flatMap(\.models) }

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Model")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            VStack(spacing: 8) {
                ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let iconURL = section.iconURL {
                                ACPIconView(url: iconURL, size: 14)
                            }
                            Text(section.title)
                                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                        }
                        .padding(.horizontal, 4)

                        ForEach(section.models, id: \.key) { model in
                            let index = flatModels.firstIndex(where: { $0.key == model.key }) ?? 0
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                                        .foregroundStyle(ClaudeTheme.textPrimary)
                                    Text(model.description)
                                        .font(.system(size: ClaudeTheme.size(11)))
                                        .foregroundStyle(ClaudeTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if effectiveProvider == model.provider && effectiveModel == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(ClaudeTheme.accent)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(index == selectedIndex ? ClaudeTheme.accentSubtle : ClaudeTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                            .onTapGesture {
                                appState.setSessionModel(model.id, provider: model.provider, in: windowState)
                                dismiss()
                            }
                        }
                    }
                }
            }

            Text("↑↓ Select  ↵ Confirm  esc Cancel")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(20)
        .frame(width: 380)
        .background(ClaudeTheme.background)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            selectedIndex = (selectedIndex - 1 + flatModels.count) % flatModels.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = (selectedIndex + 1) % flatModels.count
            return .handled
        }
        .onKeyPress(.return) {
            let model = flatModels[selectedIndex]
            appState.setSessionModel(model.id, provider: model.provider, in: windowState)
            dismiss()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            selectedIndex = flatModels.firstIndex { $0.provider == effectiveProvider && $0.id == effectiveModel } ?? 0
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

// MARK: - Effort Picker Sheet

struct EffortPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    // 0 = Auto (nil), 1...n = availableEfforts
    private let items: [String?] = [nil] + AppState.availableEfforts.map { Optional($0) }

    private var effectiveEffort: String? { windowState.sessionEffort }

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Effort Level")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            VStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let effort = items[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effort.map { effortDisplayName($0) } ?? "Auto")
                                .foregroundStyle(ClaudeTheme.textPrimary)
                            if effort == "max" {
                                Text("Opus 4.6 only")
                                    .font(.caption2)
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                            }
                        }
                        Spacer()
                        if effectiveEffort == effort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ClaudeTheme.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(index == selectedIndex ? ClaudeTheme.accentSubtle : ClaudeTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    .onTapGesture {
                        appState.setSessionEffort(effort, in: windowState)
                        dismiss()
                    }
                }
            }

            Text("↑↓ Select  ↵ Confirm  esc Cancel")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(20)
        .frame(width: 300)
        .background(ClaudeTheme.background)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = (selectedIndex + 1) % items.count
            return .handled
        }
        .onKeyPress(.return) {
            appState.setSessionEffort(items[selectedIndex], in: windowState)
            dismiss()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            selectedIndex = items.firstIndex(where: { $0 == effectiveEffort }) ?? 0
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

#Preview {
    MainView()
        .environment(AppState())
        .environment(WindowState())
}
