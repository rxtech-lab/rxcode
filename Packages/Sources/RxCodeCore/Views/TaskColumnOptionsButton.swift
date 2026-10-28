import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared editor entry point. Only the sort is passed to the host's sync path.
public struct TaskColumnOptionsButton: View {
    public let column: TaskColumn
    public let board: TaskBoard
    public let sort: TaskColumnSort
    public let filterScope: String
    public let onSaveSort: (TaskColumnSort) async throws -> Void

    @AppStorage(TaskColumnFilter.storageKey) private var filters = Data()
    @State private var isPresented = false

    public init(column: TaskColumn, board: TaskBoard, sort: TaskColumnSort, filterScope: String,
                onSaveSort: @escaping (TaskColumnSort) async throws -> Void) {
        self.column = column
        self.board = board
        self.sort = sort
        self.filterScope = filterScope
        self.onSaveSort = onSaveSort
    }

    public var body: some View {
        Button {
            feedback()
            isPresented = true
        } label: {
            Image(systemName: TaskColumnFilter.load(from: filters, scope: filterScope).isEmpty
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort and filter \(column.name)")
        .accessibilityIdentifier("task-column-options-\(column.id.rawValue)")
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        #endif
        .sheet(isPresented: $isPresented) {
            TaskColumnOptionsSheet(column: column, board: board, sort: sort,
                                   filter: TaskColumnFilter.load(from: filters, scope: filterScope)) { newSort, filter in
                if newSort != sort { try await onSaveSort(newSort) }
                filters = try filter.storing(in: filters, scope: filterScope)
            }
        }
    }

    private func feedback() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

private struct TaskColumnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let column: TaskColumn
    let board: TaskBoard
    let onSave: (TaskColumnSort, TaskColumnFilter) async throws -> Void
    @State private var sort: TaskColumnSort
    @State private var filter: TaskColumnFilter
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(column: TaskColumn, board: TaskBoard, sort: TaskColumnSort, filter: TaskColumnFilter,
         onSave: @escaping (TaskColumnSort, TaskColumnFilter) async throws -> Void) {
        self.column = column
        self.board = board
        self.onSave = onSave
        _sort = State(initialValue: sort)
        _filter = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort by", selection: $sort.field) {
                        ForEach(TaskColumnSort.Field.allCases, id: \.self) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    if sort.field != .manual {
                        Picker("Direction", selection: $sort.descending) {
                            Text(sort.field == .priority ? "Highest priority first" : "Ascending").tag(false)
                            Text(sort.field == .priority ? "Lowest priority first" : "Descending").tag(true)
                        }
                    }
                } header: {
                    Text("Sorting")
                } footer: {
                    Text("Sorting syncs across devices for this column in this view. Manual order controls the run queue.")
                }

                Section {
                    choices("Priority", options: TaskPriority.allCases.map { ($0, $0.displayNameText) }, selection: $filter.priorities)
                    choices("Type", options: board.effectiveTypes.map { ($0.id, $0.name) }, selection: $filter.typeIDs)
                    choices("Tags", options: strings(board.allTags, filter.tags), selection: $filter.tags)
                    choices("Version", options: strings(board.allVersions, filter.versions), selection: $filter.versions)
                    choices("Milestone", options: strings(board.allMilestones, filter.milestones), selection: $filter.milestones)
                    choices("Story", options: board.stories.map { ($0.id, $0.title) }, selection: $filter.storyIDs)
                    Button("Clear Filters") { filter = TaskColumnFilter() }
                        .disabled(filter.isEmpty)
                } header: {
                    Text("Filters on This Device")
                } footer: {
                    Text("Filters apply only to this column in this view on this device. Tasks must match every selected tag and any selection within each other property.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(column.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { save() }.disabled(isSaving)
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView("Applying column options…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Unable to Apply Column Options", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
        .interactiveDismissDisabled(isSaving)
        .sensoryFeedback(.selection, trigger: sort)
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func strings(_ options: [String], _ selected: [String]) -> [(String, String)] {
        Array(Set(options + selected)).sorted().map { ($0, $0) }
    }

    private func choices<Value: Hashable>(_ title: String, options: [(Value, String)], selection: Binding<[Value]>) -> some View {
        NavigationLink {
            Group {
                if options.isEmpty {
                    ContentUnavailableView("No Options", systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(options, id: \.0) { value, name in
                            Toggle(name, isOn: Binding(
                                get: { selection.wrappedValue.contains(value) },
                                set: { selected in
                                    var values = selection.wrappedValue
                                    values.removeAll { $0 == value }
                                    if selected { values.append(value) }
                                    selection.wrappedValue = values
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(title)
        } label: {
            LabeledContent(title, value: selection.wrappedValue.isEmpty ? String(localized: "All") : "\(selection.wrappedValue.count)")
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await onSave(sort, filter)
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
            }
        }
    }
}
