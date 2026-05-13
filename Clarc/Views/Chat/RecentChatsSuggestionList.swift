import SwiftUI
import ClarcCore

/// Shown below the input box on empty state so the user can quickly resume a recent chat.
struct RecentChatsSuggestionList: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if shouldShow {
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.id) { summary in
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
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()

                    if summary.id != suggestions.last?.id {
                        ClaudeThemeDivider()
                    }
                }
            }
            .background(ClaudeTheme.background)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var shouldShow: Bool {
        guard windowState.selectedProject != nil else { return false }
        guard windowState.currentSessionId == nil else { return false }
        return !suggestions.isEmpty
    }

    private var suggestions: [ChatSession.Summary] {
        guard let projectId = windowState.selectedProject?.id else { return [] }
        return appState.allSessionSummaries
            .filter { $0.projectId == projectId }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.updatedAt > b.updatedAt
            }
            .prefix(5)
            .map { $0 }
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
