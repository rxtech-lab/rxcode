import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Dedicated project window — shares AppState, WindowState.isProjectWindow = true
struct ProjectWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var inspectorStarted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(AppStorageKeys.showRightSidebar) private var showRightSidebar = false

    /// Re-runs the new-chat hooks (e.g. the Autopilot `.env` banner) whenever the
    /// open project or the active session changes — so the banner appears on
    /// opening the chat screen, not only after the first message is sent.
    private var newChatHookKey: String {
        "\(windowState.selectedProject?.id.uuidString ?? "none")|\(windowState.currentSessionId ?? "new")"
    }

    private var navigationTitleText: String {
        if windowState.showingBriefing {
            return "Briefing"
        }
        if let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title,
           !title.isEmpty {
            return title
        }
        return windowState.selectedProject?.name ?? ""
    }

    var body: some View {
        Group {
            if windowState.isInitialized {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        NavigationSplitView(columnVisibility: $columnVisibility) {
                            sidebarContent
                        } detail: {
                            detailContent
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            Button("") {
                                columnVisibility = (columnVisibility == .all) ? .detailOnly : .all
                            }
                            .keyboardShortcut("3", modifiers: .command)
                            .hidden()
                        }
                        .id(appState.themeRevision)
                        .navigationTitle(navigationTitleText)
                        .onChange(of: showRightSidebar) { _, isShowing in
                            if isShowing, !inspectorStarted { inspectorStarted = true }
                        }
                        .onChange(of: appState.focusMode) { _, newValue in
                            windowState.focusMode = newValue
                        }
                        .onAppear {
                            windowState.focusMode = appState.focusMode
                            if showRightSidebar { inspectorStarted = true }
                        }

                        if inspectorStarted {
                            RightInspectorPanel(
                                maxAllowedWidth: RightInspectorPanelLayout.maximumWidth(in: proxy.size.width)
                            )
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
            }
        }
        .onAppear {
            windowState.isProjectWindow = true
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
        .alert("Error", isPresented: Bindable(windowState).showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(windowState.errorMessage ?? ""))
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            ProjectTreeView()
        }
        .background(ClaudeTheme.sidebarBackground.ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    }

    // MARK: - Chat Toolbar Area

    private var chatToolbarArea: some View {
        HStack(spacing: 12) {
            if let project = windowState.selectedProject {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: ClaudeTheme.size(11)))
                    Text(project.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(ClaudeTheme.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ClaudeTheme.accent, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfaceElevated)
    }

    // MARK: - Detail

    private var detailContent: some View {
        Group {
            if windowState.showingBriefing {
                BriefingView()
            } else if windowState.selectedProject != nil {
                VStack(spacing: 0) {
                    chatToolbarArea
                    ClaudeThemeDivider()
                    ChatView(inputAccessory: {
                        HStack(spacing: 8) {
                            ChatToolbarControls(placement: .composer)
                            BranchPickerChip()
                        }
                    }, bottomAccessory: {
                        RecentChatsSuggestionList()
                    }, aboveInputAccessory: {
                        VStack(spacing: 8) {
                            PermissionQueueBanner()
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
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ThreadTitlePopoverButton(title: navigationTitleText)
            }
            RxCodeToolbarContent()
        }
        .background(UnifiedTitleBarAccessor())
        .focusedValue(\.startNewChat) {
            appState.startNewChat(in: windowState)
        }
    }

}
