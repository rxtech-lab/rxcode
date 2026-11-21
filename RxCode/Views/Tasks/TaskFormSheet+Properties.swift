import RxCodeCore
import SwiftUI

extension TaskFormSheet {
    /// The task's column, normalized so a status whose column was deleted
    /// still selects a picker row.
    var statusBinding: Binding<TaskStatus> {
        Binding(
            get: { board.resolvedStatus(of: task) },
            set: { task.status = $0 }
        )
    }

    var classificationSection: some View {
        Section {
            if !isStory {
                Picker("Status", selection: statusBinding) {
                    ForEach(board.effectiveColumns) { column in
                        Text(column.name).tag(column.id)
                    }
                }
                // Only the stored status locks the picker, so a new task can still
                // be created straight into a chat column.
                .disabled(isStatusLocked)
                .help(isStatusLocked ? "The agent is working on this task; it moves on when the turn finishes." : "")

                Picker("Story", selection: storyBinding) {
                    Text("None").tag(UUID?.none)
                    ForEach(appState.stories(projectFilter: task.projectId)) { story in
                        Text(story.title).tag(UUID?.some(story.id))
                    }
                }

                TaskParentCombo(projectId: task.projectId, taskID: task.id, selection: $task.parentTaskIds)
                .help("Move this task to In Progress when every linked task reaches Pending Review or Done")
            }

            typeMenu

            Picker(selection: field(\.priority, \.priority)) {
                Text("None").tag(TaskPriority?.none)
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Label {
                        Text(priority.displayName)
                    } icon: {
                        Image(systemName: priority.systemImage)
                            .foregroundStyle(priority.tint)
                    }
                    .tag(TaskPriority?.some(priority))
                }
            } label: {
                Text("Priority")
            }

            TaskSingleValueCombo(
                title: "Version",
                prompt: "Search or create a version",
                icon: "tag",
                tint: ClaudeTheme.accent,
                value: field(\.version, \.version),
                input: $versionInput,
                options: board.allVersions,
                manageTitle: "Manage Versions…",
                onManage: { fieldsSheet = .versions }
            )

            TaskSingleValueCombo(
                title: "Milestone",
                prompt: "Search or create a milestone",
                icon: "flag",
                tint: ClaudeTheme.statusSuccess,
                value: field(\.milestone, \.milestone),
                input: $milestoneInput,
                options: board.allMilestones,
                manageTitle: "Manage Milestones…",
                onManage: { fieldsSheet = .milestones }
            )
        } header: {
            HStack {
                Text("Properties")
                Spacer()
                Button {
                    showingAutoFillPopover = true
                } label: {
                    if isAutoFilling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Auto-fill", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isAutoFilling || isGeneratingTitle || !hasSuggestionInput)
                .help("Choose a model to fill in empty properties")
                .accessibilityIdentifier("task-form-auto-fill")
                .popover(isPresented: $showingAutoFillPopover, arrowEdge: .bottom) {
                    autoFillPopover
                }
                Button {
                    fieldsSheet = .tags
                } label: {
                    Label("Manage Fields…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Rename or delete types, labels, versions and milestones")
            }
        }
    }

    private var autoFillPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Auto-fill Properties")
                .font(.headline)
            Text("Fill empty properties using the selected model.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("AI model") {
                SuggestionAgentMenu(agent: $suggestionAgent, persistsSelection: false)
                    .accessibilityIdentifier("task-form-auto-fill-model")
            }
            HStack {
                Spacer()
                Button("Cancel") { showingAutoFillPopover = false }
                Button("Auto-fill") {
                    showingAutoFillPopover = false
                    autoFill()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAutoFilling || isGeneratingTitle || !hasSuggestionInput)
                .accessibilityIdentifier("task-form-auto-fill-confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    /// Types are picked from a dropdown; adding, renaming and recoloring
    /// happen in the fields sheet so every story and task shares one list.
    var typeMenu: some View {
        let typeId = field(\.typeId, \.typeId)
        let selected = board.itemType(id: typeId.wrappedValue)
        return LabeledContent("Type") {
            Menu {
                Button {
                    typeId.wrappedValue = nil
                } label: {
                    if selected == nil {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
                Divider()
                ForEach(board.effectiveTypes) { type in
                    Button {
                        typeId.wrappedValue = type.id
                    } label: {
                        Label {
                            Text(type.name)
                        } icon: {
                            Image(systemName: type.id == selected?.id ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(type.tint)
                        }
                    }
                }
                Divider()
                Button("Manage Types…") {
                    fieldsSheet = .types
                }
            } label: {
                HStack(spacing: 5) {
                    if let selected {
                        TaskColorDot(color: selected.tint)
                        Text(selected.name)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                    } else {
                        Text("None")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .font(.system(size: ClaudeTheme.size(12)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("task-form-type")
        }
    }

    var tagsSection: some View {
        let tags = isStory ? story.tags : task.tags
        let unused = board.allTags.filter { !tags.contains($0) }
        return Section {
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        TaskRemovableChip(text: tag, tint: board.tint(forTag: tag)) {
                            removeTag(tag)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TaskComboField(
                    title: "Add a tag",
                    prompt: "Search or create a tag",
                    text: $tagInput,
                    options: unused.map { TaskComboOption(name: $0, color: board.tint(forTag: $0)) },
                    onSubmit: addTag,
                    onPick: appendTag,
                    showsLabel: false,
                    manageTitle: "Manage Tags…",
                    onManage: { fieldsSheet = .tags }
                )
                Button("Add", action: addTag)
                    .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            HStack {
                Text("Tags")
                Spacer()
                Button {
                    fieldsSheet = .tags
                } label: {
                    Label("Manage Tags…", systemImage: "tag")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Rename, recolor or delete this project's tags")
            }
        }
    }
}
