import RxCodeCore
import SwiftUI

extension AppState {
    /// Board and briefing pages describe the project. A chat can have its own checkout.
    func sourceControlPath(in window: WindowState) -> String? {
        guard let project = window.selectedProject, !project.isGlobalChat else { return nil }
        guard window.generalRoute == nil || window.generalRoute == .chat else { return project.path }
        guard let id = window.currentSessionId else { return window.pendingWorktreePath ?? project.path }
        return allSessionSummaries.first { $0.id == id && $0.projectId == project.id }?.worktreePath ?? project.path
    }
}

struct WindowRepositoryStatus: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var repository = RepositoryStatus()

    func body(content: Content) -> some View {
        let path = appState.sourceControlPath(in: windowState)
        content
            .environment(repository)
            .task(id: path) { await repository.observe(path) }
    }
}

struct SidebarRepositoryView: View {
    let project: Project
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(RepositoryStatus.self) private var repository

    var body: some View {
        let path = appState.sourceControlPath(in: windowState)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Source control")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                Spacer(minLength: 8)
                Text(project.name)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom, 2)
            switch repository.path == path ? repository.state : .loading {
            case .ready(let tree):
                Button { open(.branch) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.branch")
                            .symbolRenderingMode(.monochrome)
                        Text(tree.isDetached ? String(localized: "Detached at \(tree.head)") : tree.head)
                            .font(.system(size: ClaudeTheme.size(13), weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View branches in \(tree.root)")
                .accessibilityLabel(tree.isDetached ? String(localized: "Detached at \(tree.head)") : tree.head)
                .accessibilityIdentifier("sidebar-git-branches")
                Button { open(.changes) } label: {
                    HStack(spacing: 8) {
                        if tree.changes.staged.isEmpty && tree.changes.unstaged.isEmpty {
                            Label("Working tree clean", systemImage: "checkmark.circle")
                                .foregroundStyle(ClaudeTheme.statusSuccess)
                        } else {
                            if !tree.changes.staged.isEmpty {
                                Label("\(tree.changes.staged.count) staged", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(ClaudeTheme.statusSuccess)
                            }
                            if !tree.changes.unstaged.isEmpty {
                                Label("\(tree.changes.unstaged.count) unstaged", systemImage: "circle.dashed")
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "sidebar.right")
                    }
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Review working tree changes")
                .accessibilityLabel(tree.changes.staged.isEmpty && tree.changes.unstaged.isEmpty
                    ? String(localized: "Working tree clean")
                    : String(localized: "\(tree.changes.staged.count) staged, \(tree.changes.unstaged.count) unstaged"))
                .accessibilityIdentifier("sidebar-git-changes")
            case .loading:
                Label("Checking repository…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
            case .notRepository:
                Button { open(.branch) } label: {
                    Label("Set up Git…", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.link)
            case .unavailable:
                HStack {
                    Label("Status unavailable", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry") {
                        if let path { Task { await repository.refresh(at: path) } }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.35))
    }

    private func open(_ tab: InspectorReviewTab) {
        windowState.inspectorMode = .review
        windowState.inspectorReviewTab = tab
        appState.showRightSidebar = true
    }
}
