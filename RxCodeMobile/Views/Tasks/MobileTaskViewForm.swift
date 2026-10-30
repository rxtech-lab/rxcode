import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct MobileViewEditorPayload: Identifiable {
    let view: TaskSavedView
    var id: UUID { view.id }
}

struct MobileTaskViewForm: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let onSave: (TaskSavedView) -> Void
    @State private var draft: TaskSavedView
    @State private var metadataField: TaskMetadataEdit.Field?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(projectID: UUID, view: TaskSavedView, onSave: @escaping (TaskSavedView) -> Void) {
        self.projectID = projectID
        self.onSave = onSave
        _draft = State(initialValue: view)
    }

    private var board: TaskBoard { state.taskBoard(for: projectID) }

    var body: some View {
        Form {
            Section("View") {
                TextField("Name", text: $draft.name)
                Picker("Layout", selection: $draft.layout) {
                    ForEach(TaskViewLayout.allCases, id: \.self) { layout in
                        Label { Text(layout.displayName) } icon: { Image(systemName: layout.systemImage) }
                            .tag(layout)
                    }
                }
            }

            Section("Statuses") {
                ForEach(board.effectiveColumns) { column in
                    Toggle(column.name, isOn: statusBinding(column.id))
                }
            }

            if draft.hasFilterScript {
                Section("Swift Filter") {
                    Label("Managed on Mac", systemImage: "lock")
                    Text("Edit this view's Swift filter in RxCode on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                filterLink(
                    "Stories",
                    options: board.stories.map { ($0.id, $0.title) },
                    selection: $draft.storyIds
                )
                filterLink(
                    "Versions",
                    options: listed(board.allVersions, draft.versions),
                    selection: $draft.versions,
                    field: .versions
                )
                filterLink(
                    "Milestones",
                    options: listed(board.allMilestones, draft.milestones),
                    selection: $draft.milestones,
                    field: .milestones
                )
                filterLink(
                    "Tags",
                    options: listed(board.allTags, draft.tags),
                    selection: $draft.tags,
                    field: .tags
                )
            } header: {
                Text("Filters")
            } footer: {
                Text("Items match any selected story, version and milestone, and must carry every selected tag.")
            }
        }
        .navigationTitle("View")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $metadataField) { field in
            TaskMetadataSheet(board: board, field: field) { edit in
                try await state.saveMetadata(edit, projectID: projectID)
                edit.apply(to: &draft)
            }
        }
        .overlay {
            if isSaving { ProgressView("Saving…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    private func statusBinding(_ status: TaskStatus) -> Binding<Bool> {
        let columns = board.effectiveColumns
        return Binding(
            get: { draft.visibleColumns(in: columns).contains { $0.id == status } },
            set: { isOn in
                var selected = Set(draft.visibleColumns(in: columns).map(\.id))
                if isOn { selected.insert(status) } else { selected.remove(status) }
                guard !selected.isEmpty else { return }
                draft.statuses = selected.count == columns.count ? [] : columns.map(\.id).filter(selected.contains)
            }
        )
    }

    private func filterLink<Value: Hashable>(
        _ title: LocalizedStringKey,
        options: [(Value, String)],
        selection: Binding<[Value]>,
        field: TaskMetadataEdit.Field? = nil
    ) -> some View {
        NavigationLink {
            MobileFilterValuesList(title: title, options: options, selection: selection, onManage: field.map { field in
                { MobileHaptics.buttonTap(); metadataField = field }
            })
        } label: {
            LabeledContent(title) {
                Text(summary(of: selection.wrappedValue, in: options))
            }
        }
    }

    private func summary<Value: Hashable>(of selected: [Value], in options: [(Value, String)]) -> String {
        switch selected.count {
        case 0: return String(localized: "Any")
        case 1: return options.first { $0.0 == selected[0] }?.1 ?? String(localized: "1 selected")
        default: return String(localized: "\(selected.count) selected")
        }
    }

    /// The board's values plus any selected value no item uses anymore, so a
    /// stale selection stays visible and can be switched off.
    private func listed(_ values: [String], _ selected: [String]) -> [(String, String)] {
        (values + selected.filter { !values.contains($0) }).map { ($0, $0) }
    }

    private func save() {
        var saved = draft
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deleted stories can't be shown or unselected, so they don't persist.
        saved.storyIds.removeAll { board.story(id: $0) == nil }
        guard !saved.name.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await state.saveView(saved, projectID: projectID)
                onSave(saved)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Multi-select checklist for one view filter condition.
private struct MobileFilterValuesList<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Value, String)]
    @Binding var selection: [Value]
    var onManage: (() -> Void)?

    var body: some View {
        List {
            ForEach(options, id: \.0) { value, label in
                Button {
                    toggle(value)
                } label: {
                    HStack {
                        Text(label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(value) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .overlay {
            if options.isEmpty {
                ContentUnavailableView("Nothing to filter by yet", systemImage: "line.3.horizontal.decrease")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onManage {
                ToolbarItem(placement: .primaryAction) {
                    Button("Manage…", action: onManage)
                }
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { MobileHaptics.buttonTap(); selection = [] }
                }
            }
        }
    }

    private func toggle(_ value: Value) {
        MobileHaptics.buttonTap()
        if selection.contains(value) {
            selection.removeAll { $0 == value }
        } else {
            selection.append(value)
        }
    }
}
