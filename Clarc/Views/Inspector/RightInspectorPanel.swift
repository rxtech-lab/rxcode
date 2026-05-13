import SwiftUI
import ClarcCore

// MARK: - RightInspectorPanel

/// Right-side panel with two modes:
/// - Review: Last turn / Unstaged / Staged / Branch tabs.
/// - Inspector: Memo / Terminal tabs.
struct RightInspectorPanel: View {
    @Environment(WindowState.self) private var windowState

    // Inspector-mode state lives here so reset/clear buttons in the header
    // can drive the embedded views.
    @State private var inspectorProcess = TerminalProcess()
    @State private var terminalResetID = UUID()
    @State private var memoClearID: UUID? = nil
    @State private var terminalFocusID: UUID? = nil
    @State private var memoFocusID: UUID? = nil

    private func bumpFocus(for tab: InspectorTab) {
        switch tab {
        case .terminal: terminalFocusID = UUID()
        case .memo: memoFocusID = UUID()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ClaudeThemeDivider()

            Group {
                switch windowState.inspectorMode {
                case .review:
                    reviewContent
                case .inspector:
                    InspectorContentView(
                        inspectorProcess: $inspectorProcess,
                        terminalResetID: terminalResetID,
                        memoClearID: memoClearID,
                        terminalFocusID: terminalFocusID,
                        memoFocusID: memoFocusID
                    )
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
        .onChange(of: windowState.inspectorTab) { _, newTab in
            if windowState.inspectorMode == .inspector { bumpFocus(for: newTab) }
        }
        .onChange(of: windowState.inspectorMode) { _, newMode in
            if newMode == .inspector, windowState.showInspector {
                bumpFocus(for: windowState.inspectorTab)
            }
        }
        .onChange(of: windowState.showInspector) { _, isShowing in
            if isShowing, windowState.inspectorMode == .inspector {
                bumpFocus(for: windowState.inspectorTab)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            ModeSwitchControl(selection: Bindable(windowState).inspectorMode)

            switch windowState.inspectorMode {
            case .review:
                ReviewTabControl(selection: Bindable(windowState).inspectorReviewTab)
            case .inspector:
                InspectorTabControl(
                    selection: Bindable(windowState).inspectorTab,
                    onTabClick: { tab in bumpFocus(for: tab) }
                )
            }

            Spacer()

            if windowState.inspectorMode == .inspector {
                if windowState.inspectorTab == .terminal {
                    InspectorIconButton(help: "Reset Terminal") {
                        inspectorProcess.terminate()
                        inspectorProcess = TerminalProcess()
                        terminalResetID = UUID()
                    }
                } else if windowState.inspectorTab == .memo {
                    InspectorIconButton(help: "Clear Memo") {
                        memoClearID = UUID()
                    }
                }
            }

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
    }

    // MARK: - Review content

    @ViewBuilder
    private var reviewContent: some View {
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
}

// MARK: - ModeSwitchControl

private struct ModeSwitchControl: View {
    @Binding var selection: InspectorMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(LocalizedStringKey(mode.rawValue))
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == mode ? ClaudeTheme.textOnAccent : ClaudeTheme.textSecondary)
                        .background(
                            selection == mode ? ClaudeTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
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
