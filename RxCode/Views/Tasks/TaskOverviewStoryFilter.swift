import RxCodeCore
import SwiftUI

/// Structured filters for one overview card. The same `TaskSavedView` matching
/// rules as a project view apply to its stories, after the default view.
struct TaskOverviewStoryFilter: View {
    let projectId: UUID
    let stories: [ProjectStory]
    let board: TaskBoard
    @Binding var filter: TaskSavedView
    let isEvaluatingScript: Bool
    let scriptError: String?

    @State private var isPresented = false
    @State private var isScriptEditorPresented = false
    @State private var isGeneratingScript = false
    @State private var search = ""

    private var isActive: Bool { !filter.isEmpty || filter.hasFilterScript }

    private var matchingStories: [ProjectStory] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return stories }
        return stories.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Filter stories shown on this card")
        .accessibilityLabel("Filter stories")
        .accessibilityIdentifier("task-overview-story-filter")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            filterPopover
        }
        .sheet(isPresented: $isScriptEditorPresented) {
            TaskFilterScriptPopover(
                projectId: projectId,
                script: Binding(get: { filter.filterScript }, set: { filter.filterScript = $0 }),
                isGenerating: $isGeneratingScript,
                onClose: { isScriptEditorPresented = false },
                storyOnly: true
            )
            .interactiveDismissDisabled(isGeneratingScript)
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { search = "" }
        }
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filter stories")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer(minLength: 12)
                Button("Clear All", action: clearAll)
                    .buttonStyle(.link)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .disabled(!isActive)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Form {
                Section("Stories") {
                    TextField("Find stories", text: $search)
                        .accessibilityIdentifier("task-overview-story-filter-search")
                    if matchingStories.isEmpty {
                        Text(stories.isEmpty ? "No stories in the default view." : "No matching stories")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    } else {
                        ForEach(matchingStories) { story in
                            Toggle(
                                story.title.isEmpty ? String(localized: "Untitled story") : story.title,
                                isOn: selectionBinding(story.id, in: \.storyIds)
                            )
                            .accessibilityIdentifier("task-overview-story-option-\(story.id.uuidString)")
                        }
                    }
                }

                Section("Statuses") {
                    ForEach(board.effectiveColumns) { column in
                        Toggle(isOn: selectionBinding(column.id, in: \.statuses)) {
                            Label {
                                Text(column.name)
                            } icon: {
                                TaskStatusIcon(column: column)
                            }
                        }
                    }
                }

                filterSection(
                    "Milestones",
                    empty: "No milestones on this project yet.",
                    options: listed(board.allMilestones, filter.milestones),
                    selection: \.milestones
                )
                filterSection(
                    "Versions",
                    empty: "No versions on this project yet.",
                    options: listed(board.allVersions, filter.versions),
                    selection: \.versions
                )
                filterSection(
                    "Tags",
                    empty: "No tags on this project yet.",
                    options: listed(board.allTags, filter.tags),
                    selection: \.tags
                )

                Section("Swift Filter") {
                    HStack(spacing: 8) {
                        if isEvaluatingScript { ProgressView().controlSize(.small) }
                        Text(filter.hasFilterScript ? "Filtered by Swift code" : "No Swift filter")
                            .foregroundStyle(filter.hasFilterScript ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                        Spacer()
                        if filter.hasFilterScript {
                            Button("Remove") { filter.filterScript = nil }
                        }
                        Button {
                            isScriptEditorPresented = true
                        } label: {
                            Label(filter.hasFilterScript ? "Edit…" : "Write Filter…", systemImage: "sparkles")
                        }
                        .accessibilityIdentifier("task-overview-filter-script")
                    }
                }
            }
            .formStyle(.grouped)

            if let scriptError {
                Text(scriptError)
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 350, height: 500)
    }

    private func filterSection<Value: Hashable>(
        _ title: LocalizedStringKey,
        empty: LocalizedStringKey,
        options: [(Value, String)],
        selection: WritableKeyPath<TaskSavedView, [Value]>
    ) -> some View {
        Section(title) {
            if options.isEmpty {
                Text(empty).foregroundStyle(ClaudeTheme.textTertiary)
            } else {
                ForEach(options, id: \.0) { value, label in
                    Toggle(label, isOn: selectionBinding(value, in: selection))
                }
            }
        }
    }

    private func listed(_ values: [String], _ selected: [String]) -> [(String, String)] {
        (values + selected.filter { !values.contains($0) }).map { ($0, $0) }
    }

    private func selectionBinding<Value: Hashable>(
        _ value: Value,
        in selection: WritableKeyPath<TaskSavedView, [Value]>
    ) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: selection].contains(value) },
            set: { isOn in
                if isOn {
                    if !filter[keyPath: selection].contains(value) { filter[keyPath: selection].append(value) }
                } else {
                    filter[keyPath: selection].removeAll { $0 == value }
                }
            }
        )
    }

    private func clearAll() {
        var cleared = filter
        cleared.storyIds = []
        cleared.statuses = []
        cleared.milestones = []
        cleared.versions = []
        cleared.tags = []
        cleared.filterScript = nil
        filter = cleared
    }
}
