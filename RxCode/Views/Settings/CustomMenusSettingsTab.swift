import SwiftUI
import RxCodeCore

/// Context-menu settings for default action visibility and custom items.
/// Desktop preferences also apply to menus returned over the mobile relay.
struct CustomMenusSettingsSection: View {
    @State private var showingManager = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Menus")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Manage default and custom actions in project, thread, and briefing-card menus.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Manage…") { showingManager = true }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("manage-context-menus")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingManager) {
            ContextMenusManagerSheet()
        }
    }
}

private struct ContextMenusManagerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [CustomMenuItemRecord] = []
    @State private var editing: CustomMenuDraft?
    @State private var pendingRemoval: CustomMenuItemRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    placeholderHint
                    listSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 680)
        .onAppear(perform: reload)
        .sheet(item: $editing) { draft in
            CustomMenuEditorSheet(draft: draft, projects: appState.projects) { result in
                appState.threadStore.upsertCustomMenuItem(result.toRecord())
                appState.customMenuItemsRevision += 1
                reload()
            }
        }
        .alert("Remove menu item?", isPresented: removalBinding, presenting: pendingRemoval) { record in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                let id = record.id
                pendingRemoval = nil
                appState.threadStore.deleteCustomMenuItem(id: id)
                appState.customMenuItemsRevision += 1
                reload()
            }
        } message: { record in
            Text(verbatim: "“\(record.title)” will be removed from your custom menus.")
        }
    }

    private func reload() {
        items = appState.threadStore.allCustomMenuItems()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Menus")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Show or hide individual default and custom actions in project, thread, and briefing-card menus. Some default actions appear only when applicable. Menus sync to mobile automatically.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                editing = CustomMenuDraft()
            } label: {
                Label("Add Item", systemImage: "plus")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var placeholderHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "curlybraces")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            Text("URLs, bodies, and messages can use placeholders: {{projectName}}, {{projectPath}}, {{gitHubRepo}}, {{branch}}, {{sessionId}}.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - List

    private var listSection: some View {
        VStack(spacing: 6) {
            ForEach(BuiltInContextMenuAction.all) { action in
                BuiltInMenuRow(action: action, isVisible: Binding(
                    get: { !appState.hiddenDefaultContextMenuActionIDs.contains(action.id) },
                    set: { visible in
                        if visible {
                            appState.hiddenDefaultContextMenuActionIDs.remove(action.id)
                        } else {
                            appState.hiddenDefaultContextMenuActionIDs.insert(action.id)
                        }
                    }
                ))
            }
            ForEach(items) { record in
                CustomMenuRow(
                    record: record,
                    projectName: projectName(for: record.projectId),
                    onEdit: { editing = CustomMenuDraft(record: record) },
                    onToggle: { enabled in
                        record.isEnabled = enabled
                        appState.threadStore.upsertCustomMenuItem(record)
                        appState.customMenuItemsRevision += 1
                        reload()
                    },
                    onRemove: { pendingRemoval = record }
                )
            }
        }
    }

    private func projectName(for id: UUID?) -> String {
        guard let id else { return "All projects" }
        return appState.projects.first(where: { $0.id == id })?.name ?? "Unknown project"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}

// MARK: - Default Action Row

private struct BuiltInMenuRow: View {
    let action: BuiltInContextMenuAction
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.systemImage)
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(action.title))
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                HStack(spacing: 6) {
                    Text("Default")
                    ForEach(action.surfaces, id: \.self) { surface in
                        Text(LocalizedStringKey(surface.rawValue.capitalized))
                    }
                }
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(isOn: $isVisible) { Text(LocalizedStringKey(action.title)) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Row

private struct CustomMenuRow: View {
    let record: CustomMenuItemRecord
    let projectName: String
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.systemImage ?? "circle")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.title)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                HStack(spacing: 6) {
                    ForEach(record.surfaces, id: \.self) { badge(surfaceLabel($0)) }
                    badge(actionLabel)
                    if record.conditionTypeValue == .swiftScript {
                        badge("Conditional")
                    }
                    Text(verbatim: projectName)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { record.isEnabled }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Menu {
                Button("Edit…", action: onEdit)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func surfaceLabel(_ surface: CustomMenuItemRecord.Surface) -> String {
        switch surface {
        case .project: return "Project"
        case .thread: return "Thread"
        case .briefing: return "Briefing"
        }
    }

    private var actionLabel: String {
        switch record.actionKindValue {
        case .callAPI: return "Call API"
        case .createThread: return "New thread"
        case .continueThread: return "Continue thread"
        }
    }
}
