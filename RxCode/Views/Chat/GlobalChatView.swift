import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct GlobalChatView: View {
    @Environment(WindowState.self) private var windowState
    @SceneStorage("globalChatSidebarVisible") private var showsSidebar = true
    @State private var showsPlan = false
    @State private var showsPlanSidebar = false

    private var sidebarVisible: Bool { showsPlan ? showsPlanSidebar : showsSidebar }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                GlobalChatSidebar()
                    .frame(width: 260)
                    .transition(.move(edge: .leading))

                Rectangle()
                    .fill(ClaudeTheme.divider)
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if showsPlan { showsPlanSidebar.toggle() } else { showsSidebar.toggle() }
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: ClaudeTheme.size(14)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .help(sidebarVisible ? "Hide chat sidebar" : "Show chat sidebar")
                    .accessibilityIdentifier("global-chat-sidebar-toggle")

                    if !sidebarVisible {
                        GlobalNewChatButton()
                    }

                    if let project = windowState.selectedProject, !project.isGlobalChat {
                        Label(project.name, systemImage: "folder")
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                            .help(project.path)
                    }

                    Spacer()
                    ChatCreationMenu()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .frame(height: GlobalChatLayout.headerHeight)

                ClaudeThemeDivider()

                ChatView(inputAccessory: {
                    HStack(spacing: 8) {
                        ChatToolbarControls(placement: .composer)
                        if windowState.selectedProject?.isGlobalChat == false {
                            BranchPickerChip()
                        }
                    }
                }, aboveInputAccessory: {
                    VStack(spacing: 8) {
                        AgentConfirmationBanner()
                        PermissionQueueBanner()
                        ComputerUsePreviewBanner()
                        if windowState.selectedProject?.isGlobalChat == false {
                            ThreadDiffBanner()
                        }
                    }
                })
                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                .modifier(ChatDetailModifiers())
            }
            .background(ClaudeTheme.background)
        }
        .clipped()
        .onPreferenceChange(CodingPlanVisibleKey.self) { visible in
            showsPlan = visible
            if !visible { showsPlanSidebar = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("global-chat-view")
    }
}

private enum GlobalChatLayout {
    /// Shared by the sidebar and chat headers so their dividers line up.
    static let headerHeight: CGFloat = 44
}

private struct GlobalNewChatButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Button {
            appState.startNewGlobalChat(in: windowState)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .help("New Chat")
        .accessibilityIdentifier("global-new-chat")
    }
}

/// Collapsible list of chats started from the Chat tab. Picking a thread
/// opens it in the Chat tab.
private struct GlobalChatSidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                GlobalNewChatButton()
            }
            .padding(.horizontal, 14)
            .frame(height: GlobalChatLayout.headerHeight)

            ClaudeThemeDivider()

            HistoryListView(
                scopedProjectId: Project.globalChatID,
                opensInChatTab: true
            )
            // Drop the `.sidebar` list's translucent material so the panel
            // matches the theme instead of showing the desktop through it.
            .scrollContentBackground(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("global-chat-history")
        }
        .frame(maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
    }
}
