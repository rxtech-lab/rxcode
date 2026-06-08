import SwiftUI
import RxCodeCore

/// "Custom Context Menus" section embedded in the General settings tab for
/// creating and managing user-defined context-menu items.
/// Items are persisted on the desktop (`CustomMenuItemRecord`) and surfaced by
/// `CustomMenuHook` on the project / thread / briefing menus — and, because they
/// ride the existing `MenuItem` relay, on mobile too.
struct CustomMenusSettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var items: [CustomMenuItemRecord] = []
    @State private var editing: CustomMenuDraft?
    @State private var pendingRemoval: CustomMenuItemRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            placeholderHint
            listSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Custom Context Menus")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Add your own items to the project, thread, and briefing-card menus. They sync to mobile automatically.")
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
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("No custom items yet.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
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
