import RxCodeCore
import SwiftUI

/// A searchable task selection with story headings. A task is identified by
/// ID, so two tasks with the same title remain distinct choices. The dropdown
/// renders its rows lazily, so large boards stay responsive while typing.
struct TaskParentCombo: View {
    let board: TaskBoard
    let taskID: UUID
    @Binding var selection: UUID?
    @State private var search = ""
    @State private var isOpen = false
    @State private var fieldWidth: CGFloat = 240
    @State private var highlighted: UUID?
    @FocusState private var searchFocused: Bool

    /// The dropdown is this much wider than the field that opens it.
    private static let dropdownWidthScale: CGFloat = 1.5

    var body: some View {
        LabeledContent("Starts after") {
            HStack(spacing: 6) {
                if let selected = board.tasks.first(where: { $0.id == selection }) {
                    TaskRemovableChip(text: selected.title, icon: "link", tint: ClaudeTheme.accent) {
                        selection = nil
                    }
                    .frame(maxWidth: 150)
                }
                Button {
                    isOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Search tasks")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    dropdown
                }
                .help("Browse tasks by story")
                .accessibilityLabel("Browse parent tasks")
                .accessibilityIdentifier("task-parent-search")
            }
        }
    }

    private var dropdown: some View {
        let groups = board.parentTaskGroups(for: taskID, matching: search)
        let tasks = groups.flatMap(\.tasks)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Starts after", text: $search, prompt: Text("Search tasks"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($searchFocused)
                    .onSubmit {
                        if let task = tasks.first(where: { $0.id == highlighted }) ?? (tasks.count == 1 ? tasks[0] : nil) {
                            pick(task)
                        }
                    }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1, in: tasks) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1, in: tasks) }
                    .onChange(of: search) { highlighted = nil }
                    .accessibilityIdentifier("task-parent-search-field")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if search.isEmpty, selection != nil {
                            row(title: String(localized: "None"), isSelected: false, isHighlighted: false) {
                                selection = nil
                                isOpen = false
                            }
                        }
                        ForEach(Array(groups.enumerated()), id: \.offset) { entry in
                            Section {
                                ForEach(entry.element.tasks) { candidate in
                                    row(
                                        title: candidate.title,
                                        isSelected: candidate.id == selection,
                                        isHighlighted: candidate.id == highlighted
                                    ) { pick(candidate) }
                                    .id(candidate.id)
                                }
                            } header: {
                                Text(storyTitle(for: entry.element))
                                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: 360)

            if tasks.isEmpty {
                Text("No matching tasks")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: max(fieldWidth, 240) * Self.dropdownWidthScale)
        .onAppear { searchFocused = true }
        .onDisappear {
            search = ""
            highlighted = nil
        }
    }

    private func row(title: String, isSelected: Bool, isHighlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isHighlighted ? ClaudeTheme.accent.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moveHighlight(by offset: Int, in tasks: [ProjectTask]) -> KeyPress.Result {
        guard !tasks.isEmpty else { return .ignored }
        let current = tasks.firstIndex { $0.id == highlighted }
        let next = current.map { min(max($0 + offset, 0), tasks.count - 1) } ?? (offset > 0 ? 0 : tasks.count - 1)
        highlighted = tasks[next].id
        return .handled
    }

    private func storyTitle(for group: ParentTaskGroup) -> String {
        group.story.map { $0.title.isEmpty ? String(localized: "Untitled Story") : $0.title }
            ?? String(localized: "No Story")
    }

    private func pick(_ task: ProjectTask) {
        selection = task.id
        isOpen = false
    }
}
