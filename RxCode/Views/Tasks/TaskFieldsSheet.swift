import RxCodeCore
import SwiftUI

/// Manages one project's shared field values — types, tags, versions and
/// milestones — which every story and task in the project picks from.
/// Rename, delete, and (for types and tags) add and recolor.
///
/// Edits apply immediately, like GitHub's label settings page. There is no
/// draft, because a rename or delete rewrites every item using the value.
struct TaskFieldsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let projectId: UUID
    /// The section to scroll to on open, e.g. Types from the form's Type menu.
    var initialField: Field?

    enum Field: Hashable, Identifiable {
        case types, tags, versions, milestones

        var id: Self { self }
    }

    /// A delete waiting for confirmation.
    private enum PendingDelete: Identifiable {
        case type(TaskItemType)
        case label(String)
        case version(String)
        case milestone(String)

        var id: String {
            switch self {
            case .type(let type): return "type-\(type.id)"
            case .label(let name): return "label-\(name)"
            case .version(let name): return "version-\(name)"
            case .milestone(let name): return "milestone-\(name)"
            }
        }

        var name: String {
            switch self {
            case .type(let type): return type.name
            case .label(let name), .version(let name), .milestone(let name): return name
            }
        }
    }

    @State private var newTypeName = ""
    @State private var newLabelName = ""
    @State private var pendingDelete: PendingDelete?

    private var board: TaskBoard { appState.taskBoard(for: projectId) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    typesSection.id(Field.types)
                    tagsSection.id(Field.tags)
                    versionsSection.id(Field.versions)
                    milestonesSection.id(Field.milestones)
                }
                .formStyle(.grouped)
                .onAppear {
                    if let initialField { proxy.scrollTo(initialField, anchor: .top) }
                }
            }

            HStack {
                Text("Changes apply to every story and task in this project.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 640)
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pending in
            Button("Delete", role: .destructive) {
                delete(pending)
            }
        } message: { pending in
            Text(deleteMessage(pending))
        }
    }

    // MARK: - Types

    private var typesSection: some View {
        Section {
            ForEach(board.effectiveTypes) { type in
                TaskFieldRow(
                    name: type.name,
                    color: type.tint,
                    usage: board.tasks.filter { $0.typeId == type.id }.count
                        + board.stories.filter { $0.typeId == type.id }.count,
                    onRename: { newName in
                        var updated = type
                        updated.name = newName
                        appState.upsertItemType(updated, projectId: projectId)
                    },
                    onRecolor: { hex in
                        var updated = type
                        updated.colorHex = hex
                        appState.upsertItemType(updated, projectId: projectId)
                    },
                    onDelete: { pendingDelete = .type(type) }
                )
            }
            TaskFieldAddRow(prompt: "New type", text: $newTypeName) { name in
                let taken = board.effectiveTypes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                guard !taken else { return }
                appState.upsertItemType(
                    TaskItemType(name: name, colorHex: nextColor(after: board.effectiveTypes.count)),
                    projectId: projectId
                )
            }
        } header: {
            Text("Types")
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        Section {
            let tags = board.allTags
            if tags.isEmpty {
                emptyRow("No tags yet. Add one here, or on a story or task.")
            }
            ForEach(tags, id: \.self) { tag in
                TaskFieldRow(
                    name: tag,
                    color: board.tint(forTag: tag),
                    usage: board.tasks.filter { $0.tags.contains(tag) }.count
                        + board.stories.filter { $0.tags.contains(tag) }.count,
                    onRename: { appState.renameLabel(tag, to: $0, projectId: projectId) },
                    onRecolor: { appState.setLabelColor(tag, colorHex: $0, projectId: projectId) },
                    onDelete: { pendingDelete = .label(tag) }
                )
            }
            TaskFieldAddRow(prompt: "New tag", text: $newLabelName) { name in
                appState.addLabel(name, colorHex: nextColor(after: board.labels.count), projectId: projectId)
            }
        } header: {
            Text("Tags")
        }
    }

    // MARK: - Versions and milestones

    private var versionsSection: some View {
        Section {
            let versions = board.allVersions
            if versions.isEmpty {
                emptyRow("No versions yet. Set one on a story or task to reuse it here.")
            }
            ForEach(versions, id: \.self) { version in
                TaskFieldRow(
                    name: version,
                    icon: "tag",
                    color: ClaudeTheme.accent,
                    usage: board.tasks.filter { $0.version == version }.count
                        + board.stories.filter { $0.version == version }.count,
                    onRename: { appState.renameVersion(version, to: $0, projectId: projectId) },
                    onDelete: { pendingDelete = .version(version) }
                )
            }
        } header: {
            Text("Versions")
        }
    }

    private var milestonesSection: some View {
        Section {
            let milestones = board.allMilestones
            if milestones.isEmpty {
                emptyRow("No milestones yet. Set one on a story or task to reuse it here.")
            }
            ForEach(milestones, id: \.self) { milestone in
                TaskFieldRow(
                    name: milestone,
                    icon: "flag",
                    color: ClaudeTheme.statusSuccess,
                    usage: board.tasks.filter { $0.milestone == milestone }.count
                        + board.stories.filter { $0.milestone == milestone }.count,
                    onRename: { appState.renameMilestone(milestone, to: $0, projectId: projectId) },
                    onDelete: { pendingDelete = .milestone(milestone) }
                )
            }
        } header: {
            Text("Milestones")
        }
    }

    // MARK: - Helpers

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(ClaudeTheme.textTertiary)
    }

    private func nextColor(after count: Int) -> String {
        TaskLabel.palette[count % TaskLabel.palette.count]
    }

    private func delete(_ pending: PendingDelete) {
        switch pending {
        case .type(let type): appState.deleteItemType(type, projectId: projectId)
        case .label(let name): appState.deleteLabel(name, projectId: projectId)
        case .version(let name): appState.deleteVersion(name, projectId: projectId)
        case .milestone(let name): appState.deleteMilestone(name, projectId: projectId)
        }
        pendingDelete = nil
    }

    private func deleteMessage(_ pending: PendingDelete) -> LocalizedStringKey {
        switch pending {
        case .type: return "The type is cleared from every story and task that uses it."
        case .label: return "The tag is removed from every story, task and view that uses it."
        case .version: return "The version is cleared from every story, task and view that uses it."
        case .milestone: return "The milestone is cleared from every story and task that uses it."
        }
    }
}

// MARK: - Rows

/// One field value: color well (when recolorable) or icon, editable name,
/// usage count, delete.
private struct TaskFieldRow: View {
    let name: String
    var icon: String?
    let color: Color
    let usage: Int
    let onRename: (String) -> Void
    /// `nil` for values without a stored color (versions, milestones).
    var onRecolor: ((String) -> Void)?
    let onDelete: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let onRecolor {
                ColorPicker(
                    "Color",
                    selection: Binding(get: { color }, set: { onRecolor($0.hexString) }),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 32)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 32)
            }

            TextField("Name", text: $draft)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }

            TaskPill(text: draft.isEmpty ? name : draft, icon: onRecolor == nil ? icon : nil, tint: color)

            Text("\(usage)")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .monospacedDigit()
                .frame(minWidth: 20, alignment: .trailing)
                .help("Stories and tasks using this")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .onAppear { draft = name }
        .onChange(of: name) { _, newValue in draft = newValue }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == name {
            draft = name
        } else {
            onRename(trimmed)
        }
    }
}

private struct TaskFieldAddRow: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let onAdd: (String) -> Void

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(ClaudeTheme.accent)
            TextField(prompt, text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(trimmed.isEmpty)
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        text = ""
    }
}
