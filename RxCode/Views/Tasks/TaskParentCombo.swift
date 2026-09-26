import RxCodeCore
import SwiftUI

/// A searchable task selection with story headings. A task is identified by
/// ID, so two tasks with the same title remain distinct choices.
struct TaskParentCombo: View {
    let board: TaskBoard
    let taskID: UUID
    @Binding var selection: UUID?
    @State private var search = ""

    private var matches: [ParentTaskGroup] {
        board.parentTaskGroups(for: taskID, matching: search)
    }

    var body: some View {
        LabeledContent("Starts after") {
            HStack(spacing: 6) {
                if let selected = board.tasks.first(where: { $0.id == selection }) {
                    TaskRemovableChip(text: selected.title, icon: "link", tint: ClaudeTheme.accent) {
                        selection = nil
                    }
                    .frame(maxWidth: 150)
                }
                TextField("Starts after", text: $search, prompt: Text("Search tasks"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .onChange(of: search) { _, value in
                        guard let id = UUID(uuidString: value),
                              board.canLinkTask(taskID, to: id),
                              let candidate = board.tasks.first(where: { $0.id == id })
                        else { return }
                        pick(candidate)
                    }
                    .onSubmit {
                        let tasks = matches.flatMap(\.tasks)
                        if tasks.count == 1 { pick(tasks[0]) }
                    }
                    .textInputSuggestions {
                        ForEach(Array(matches.enumerated()), id: \.offset) { entry in
                            Section(storyTitle(for: entry.element)) {
                                ForEach(entry.element.tasks) { candidate in
                                    Label {
                                        Text(candidate.title)
                                    } icon: {
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(ClaudeTheme.textTertiary)
                                    }
                                    .frame(width: 360, alignment: .leading)
                                    .textInputCompletion(candidate.id.uuidString)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("task-parent-search")
                Menu {
                    Button("None") { selection = nil }
                    ForEach(Array(board.parentTaskGroups(for: taskID).enumerated()), id: \.offset) { entry in
                        Section(storyTitle(for: entry.element)) {
                            ForEach(entry.element.tasks) { candidate in
                                Button(candidate.title) { pick(candidate) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Browse tasks by story")
                .accessibilityLabel("Browse parent tasks")
            }
        }
    }

    private func storyTitle(for group: ParentTaskGroup) -> String {
        group.story.map { $0.title.isEmpty ? String(localized: "Untitled Story") : $0.title }
            ?? String(localized: "No Story")
    }

    private func pick(_ task: ProjectTask) {
        selection = task.id
        search = ""
    }
}
