import SwiftUI
import ClarcCore

// MARK: - RightInspectorPanel

/// Right-side review/git panel.
/// Tabs: Last turn / Unstaged / Staged / Branch.
struct RightInspectorPanel: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ReviewTabControl(selection: Bindable(windowState).inspectorReviewTab)
                Spacer()

                Button {
                    windowState.showInspector = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ClaudeThemeDivider()

            Group {
                switch windowState.inspectorReviewTab {
                case .lastTurn:
                    LastTurnDiffView()
                case .unstaged:
                    UnstagedChangesView()
                case .staged:
                    StagedChangesView()
                case .branch:
                    BranchInfoView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudeTheme.surfaceElevated)
        .frame(
            minWidth: windowState.showInspector ? 340 : 0,
            maxWidth: windowState.showInspector ? .infinity : 0
        )
        .opacity(windowState.showInspector ? 1 : 0)
        .clipped()
    }
}

// MARK: - ReviewTabControl

private struct ReviewTabControl: View {
    @Binding var selection: InspectorReviewTab

    var body: some View {
        Menu {
            ForEach(InspectorReviewTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack {
                        Text(LocalizedStringKey(tab.rawValue))
                        if selection == tab { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(selection.rawValue))
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Empty State Helper

struct InspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: ClaudeTheme.size(32)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(title)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(message)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Last Turn (placeholder; Phase 1 stub)

struct LastTurnDiffView: View {
    var body: some View {
        InspectorEmptyState(
            title: "No file changes yet",
            message: "The latest diffs are no longer available."
        )
    }
}

// MARK: - Unstaged / Staged / Branch tabs reuse the existing GitStatusView

struct UnstagedChangesView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            VStack(spacing: 0) {
                GitStatusView(projectPath: project.path)
                Spacer()
            }
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to see unstaged changes.")
        }
    }
}

struct StagedChangesView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            VStack(spacing: 0) {
                GitStatusView(projectPath: project.path)
                Spacer()
            }
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to see staged changes.")
        }
    }
}

struct BranchInfoView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let project = windowState.selectedProject {
            VStack(spacing: 0) {
                GitStatusView(projectPath: project.path)
                Spacer()
            }
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to inspect its branch.")
        }
    }
}
