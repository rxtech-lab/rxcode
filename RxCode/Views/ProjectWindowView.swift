import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Dedicated project window — shares AppState, WindowState.isProjectWindow = true
struct ProjectWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var inspectorStarted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                    .id(appState.themeRevision)
                    .navigationTitle(navigationTitleText)
                    .onChange(of: windowState.showInspector) { _, isShowing in
                        if isShowing, !inspectorStarted { inspectorStarted = true }
                    }
                    .onChange(of: appState.focusMode) { _, newValue in
                        windowState.focusMode = newValue
                    }
                    .onAppear {
                        windowState.focusMode = appState.focusMode
                    }

                    if inspectorStarted {
                        RightInspectorPanel()
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
                        PermissionQueueBanner()
                    })
                }
                .modifier(ChatDetailModifiers())
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            RxCodeToolbarContent()
        }
        .background(UnifiedTitleBarAccessor())
        .focusedValue(\.startNewChat) {
            appState.startNewChat(in: windowState)
        }
    }

}
