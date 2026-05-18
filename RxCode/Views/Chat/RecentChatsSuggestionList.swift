import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Shown below the input box on empty state so the user can quickly resume a recent chat.
struct RecentChatsSuggestionList: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var sessionToDelete: ChatSession?

    var body: some View {
        if shouldShow {
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.id) { summary in
                    suggestionRow(summary)

                    if summary.id != suggestions.last?.id {
                        ClaudeThemeDivider()
                    }
                }
            }
            .background(ClaudeTheme.background)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .alert("Delete Session", isPresented: isDeletingSessionBinding) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        Task { await appState.deleteSession(session, in: windowState) }
                    }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                if let session = sessionToDelete {
                    Text("\"\(session.title)\" will be deleted. This action cannot be undone.")
                } else {
                    Text("This session will be deleted. This action cannot be undone.")
                }
            }
            .alert("Rename Session", isPresented: isRenamingBinding) {
                TextField("Session name", text: $renameText)
                Button("Rename") {
                    if let session = renamingSession, !renameText.isEmpty {
                        Task { await appState.renameSession(session, to: renameText) }
                    }
                    renamingSession = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingSession = nil
                }
            }
        }
    }

    private func suggestionRow(_ summary: ChatSession.Summary) -> some View {
        Button {
            appState.selectSession(id: summary.id, in: windowState)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)

                Text(summary.title)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if summary.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: ClaudeTheme.size(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .contextMenu {
            let chatSession = summary.makeSession()

            Button {
                renameText = summary.title
                renamingSession = chatSession
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                Task { await appState.togglePinSession(chatSession) }
            } label: {
                if summary.isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin")
                }
            }

            Button {
                Task {
                    if summary.isArchived {
                        await appState.unarchiveSession(chatSession, in: windowState)
                    } else {
                        await appState.archiveSession(chatSession, in: windowState)
                    }
                }
            } label: {
                if summary.isArchived {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                } else {
                    Label("Archive", systemImage: "archivebox")
                }
            }

            Divider()

            Button(role: .destructive) {
                sessionToDelete = chatSession
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var shouldShow: Bool {
        guard windowState.selectedProject != nil else { return false }
        guard windowState.currentSessionId == nil else { return false }
        // Mirror ChatView.isEmptyState: avoid showing the suggestion list under
        // an active conversation when messages briefly outlive the session id
        // (e.g. just after a streaming session ends and currentSessionId resets).
        guard chatBridge.messages.isEmpty, !chatBridge.isStreaming else { return false }
        return !suggestions.isEmpty
    }

    private var suggestions: [ChatSession.Summary] {
        guard let projectId = windowState.selectedProject?.id else { return [] }
        let scoped = appState.allSessionSummaries
            .filter { $0.projectId == projectId && !$0.isArchived }
        let pinned = scoped
            .filter { $0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
        // Always surface at least 4 unpinned suggestions; when pinned fill
        // fewer than 6 slots, expand the unpinned section to keep the total
        // at 6.
        let unpinnedLimit = max(4, 6 - pinned.count)
        let unpinned = scoped
            .filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(unpinnedLimit)
        return Array(pinned) + Array(unpinned)
    }

    private var isDeletingSessionBinding: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }
}

// MARK: - Hover Highlight

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.5) : Color.clear)
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}
