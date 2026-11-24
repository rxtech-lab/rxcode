import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

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
        configure(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(from: nsView)
    }

    private func configure(from view: NSView?) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            // Group windows into native macOS tabs. The default `.automatic`
            // mode only tabs in full screen (it honours the system "Prefer tabs
            // when opening documents" setting), so opening a second window just
            // floats free. `.preferred` always merges new windows into a tab
            // bar; the shared identifier keeps every main/project window in one
            // tab group so they can be merged together.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "rxcode.main"
        }
    }
}

// MARK: - Project Tab Button (isolated — isSelected passed as value, body reads no @Observable properties)

struct ProjectTabButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

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
                AttentionBadge(attention: appState.projectAttention(projectId: project.id, in: windowState))
                if let phase = appState.cloudSyncPhaseByProjectId[project.id] {
                    ProgressView(value: phase.fractionCompleted)
                        .progressViewStyle(.linear)
                        .frame(width: 24)
                        .help(phase.progressText)
                        .accessibilityLabel(phase.progressText)
                        .accessibilityIdentifier("project-tab-sync-progress-\(project.id.uuidString)")
                }
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
        .contextMenu {
            let hookItems = appState.projectContextMenuItems(for: project)
            if !hookItems.isEmpty {
                HookContextMenuItems(items: hookItems)
                Divider()
            }
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
            ForEach(InspectorTab.availableCases, id: \.self) { tab in
                Button {
                    selection = tab
                    onTabClick(tab)
                } label: {
                    Text(tab.title)
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
                        Text(tab.title)
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
