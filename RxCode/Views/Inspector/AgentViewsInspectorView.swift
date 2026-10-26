import RxCodeCore
import SwiftUI

/// Inspector "Views" tab: the `ide__show_ui` dialog views the current thread
/// has shown. Clicking a row reopens its dialog; the close button removes it.
struct AgentViewsInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var views: [AgentUIDialog] {
        appState.agentUIViews(forSession: windowState.currentSessionId ?? windowState.newSessionKey)
    }

    var body: some View {
        let views = views
        if views.isEmpty {
            ContentUnavailableView {
                Label("No Views", systemImage: "rectangle.3.group")
            } description: {
                Text("Views an agent opens in a dialog in this thread appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(views.reversed()) { view in
                        AgentViewRow(view: view)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

private struct AgentViewRow: View {
    @Environment(AppState.self) private var appState
    let view: AgentUIDialog

    @State private var isHovering = false

    private var title: String {
        view.title ?? String(localized: "Interactive View")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.openAgentUIView(id: view.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.accent)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        Text("\(view.spec.elements.count) elements")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(title)")

            if isHovering {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { appState.removeAgentUIView(id: view.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from Views")
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(isHovering ? ClaudeTheme.textPrimary.opacity(0.05) : Color.clear)
        )
        .padding(.horizontal, 8)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                appState.openAgentUIView(id: view.id)
            } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button(role: .destructive) {
                appState.removeAgentUIView(id: view.id)
            } label: {
                Label("Remove", systemImage: "xmark")
            }
        }
        .accessibilityIdentifier("agent-view-\(view.id.uuidString)")
    }
}
