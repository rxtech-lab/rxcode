import RxCodeCore
import RxCodeSync
import SwiftUI

/// Create or edit a task. Saving sends the whole task to the desktop, which
/// dispatches it to its agent if it lands in a chat column.
struct MobileTaskFormView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var task: ProjectTask
    let isNew: Bool

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(task: ProjectTask, isNew: Bool) {
        _task = State(initialValue: task)
        self.isNew = isNew
    }

    private var board: TaskBoard { state.taskBoard(for: task.projectId) }
    private var isStatusLocked: Bool { !isNew && board.isStatusLocked(task) }

    private var canSave: Bool {
        !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $task.title)
                    .accessibilityIdentifier("task-form-title")
                TextField("Description", text: $task.details, axis: .vertical)
                    .lineLimit(4...12)
                    .disabled(task.isDescriptionLocked)
            } footer: {
                if task.isDescriptionLocked {
                    Label("The description is locked once a task has run, so it keeps matching what the agent was asked to do.", systemImage: "lock")
                }
            }

            Section {
                Picker("Status", selection: $task.status) {
                    ForEach(board.effectiveColumns) { column in
                        Label(column.name, systemImage: column.systemImage).tag(column.id)
                    }
                }
                .disabled(isStatusLocked)
                Picker("Story", selection: $task.storyId) {
                    Text("None").tag(UUID?.none)
                    ForEach(board.stories) { story in
                        Text(story.title.isEmpty ? String(localized: "Untitled Story") : story.title)
                            .tag(Optional(story.id))
                    }
                }
                Picker("Starts after", selection: $task.parentTaskId) {
                    Text("None").tag(UUID?.none)
                    ForEach(board.tasks.filter { board.canLinkTask(task.id, to: $0.id) }) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
            } footer: {
                if isStatusLocked {
                    Text("The agent is working on this task; it moves on when the turn finishes.")
                } else if board.column(for: task.status).triggersChat, task.agent.isAssigned {
                    Text("Saving in this column runs the assigned agent on your Mac.")
                }
            }

            MobileTaskClassificationSection(
                board: board,
                priority: $task.priority,
                typeId: $task.typeId,
                version: $task.version,
                milestone: $task.milestone,
                tags: $task.tags
            )

            agentSection
        }
        .navigationTitle(isNew ? "New Task" : "Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("task-form-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .mobileTaskErrorAlert($errorMessage)
    }

    private var agentSection: some View {
        Section {
            Menu {
                Button {
                    task.agent.provider = nil
                    task.agent.model = nil
                } label: {
                    if !task.agent.isAssigned {
                        Label("Unassigned", systemImage: "checkmark")
                    } else {
                        Text("Unassigned")
                    }
                }
                ForEach(state.taskModelSections) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.key) { model in
                            Button {
                                task.agent.provider = model.provider
                                task.agent.model = model.id
                                task.agent.effort = nil
                            } label: {
                                if task.agent.provider == model.provider && task.agent.model == model.id {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    }
                }
            } label: {
                LabeledContent("Model") {
                    Text(state.taskAgentLabel(task.agent))
                        .foregroundStyle(task.agent.isAssigned ? .primary : .secondary)
                }
            }
            Toggle("Plan mode", isOn: $task.agent.planMode)
                .disabled(!task.agent.isAssigned)
        } header: {
            Text("Agent")
        } footer: {
            Text("Moving this task into a chat column runs the assigned agent in a new thread on your Mac.")
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        var toSave = task
        toSave.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSaving = false }
            do {
                try await state.saveTask(toSave)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Create or edit a story.
struct MobileStoryFormView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var story: ProjectStory
    let isNew: Bool

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(story: ProjectStory, isNew: Bool) {
        _story = State(initialValue: story)
        self.isNew = isNew
    }

    private var board: TaskBoard { state.taskBoard(for: story.projectId) }

    private var canSave: Bool {
        !story.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $story.title)
                    .accessibilityIdentifier("story-form-title")
                TextField("Description", text: $story.details, axis: .vertical)
                    .lineLimit(3...10)
            }

            MobileTaskClassificationSection(
                board: board,
                priority: $story.priority,
                typeId: $story.typeId,
                version: $story.version,
                milestone: $story.milestone,
                tags: $story.tags
            )
        }
        .navigationTitle(isNew ? "New Story" : "Edit Story")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(isNew ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("story-form-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .mobileTaskErrorAlert($errorMessage)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        var toSave = story
        toSave.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSaving = false }
            do {
                try await state.saveStory(toSave)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Create a task from a line of free text. The desktop's default agent writes
/// the title and fills in the classification in the background.
struct MobileQuickAddTaskView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State var storyID: UUID?

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var board: TaskBoard { state.taskBoard(for: projectID) }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                TextField("What needs to be done?", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($isFocused)
                    .accessibilityIdentifier("task-quick-add-text")
            } footer: {
                Text("Your Mac titles and classifies the task in the background.")
            }
            if !board.stories.isEmpty {
                Section {
                    Picker("Story", selection: $storyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(board.stories) { story in
                            Text(story.title.isEmpty ? String(localized: "Untitled Story") : story.title)
                                .tag(Optional(story.id))
                        }
                    }
                }
            }
        }
        .navigationTitle("Quick Add Task")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Add") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("task-quick-add-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .mobileTaskErrorAlert($errorMessage)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let text = text
        Task {
            defer { isSaving = false }
            do {
                try await state.quickAddTask(text: text, projectID: projectID, storyID: storyID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Classification fields

/// Priority, type, version, milestone and tags — the fields tasks and stories
/// share.
struct MobileTaskClassificationSection: View {
    let board: TaskBoard
    @Binding var priority: TaskPriority?
    @Binding var typeId: UUID?
    @Binding var version: String?
    @Binding var milestone: String?
    @Binding var tags: [String]

    @State private var newTag = ""

    var body: some View {
        Section("Details") {
            Picker("Priority", selection: $priority) {
                Text("None").tag(TaskPriority?.none)
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Label(priority.displayNameText, systemImage: priority.systemImage)
                        .tag(Optional(priority))
                }
            }
            Picker("Type", selection: $typeId) {
                Text("None").tag(UUID?.none)
                ForEach(board.effectiveTypes) { type in
                    Text(type.name).tag(Optional(type.id))
                }
            }
            suggestedTextField("Version", text: $version, suggestions: board.allVersions)
            suggestedTextField("Milestone", text: $milestone, suggestions: board.allMilestones)
        }

        Section("Tags") {
            let options = Array(Set(board.allTags + tags)).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            ForEach(options, id: \.self) { tag in
                Button {
                    if let index = tags.firstIndex(of: tag) {
                        tags.remove(at: index)
                    } else {
                        tags.append(tag)
                    }
                } label: {
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(board.labelTint(for: tag))
                        Text(tag)
                            .foregroundStyle(.primary)
                        Spacer()
                        if tags.contains(tag) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            HStack {
                TextField("New tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        if !tags.contains(tag) { tags.append(tag) }
        newTag = ""
    }

    /// A free-text field backed by an optional string, with a menu of the
    /// values already used on this board.
    private func suggestedTextField(
        _ title: LocalizedStringKey,
        text: Binding<String?>,
        suggestions: [String]
    ) -> some View {
        HStack {
            TextField(title, text: Binding(
                get: { text.wrappedValue ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    text.wrappedValue = trimmed.isEmpty ? nil : $0
                }
            ))
            .textInputAutocapitalization(.never)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { value in
                        Button(value) { text.wrappedValue = value }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Follow-up

/// Sends a follow-up message into a task's existing chat, which moves the task
/// back into progress.
struct MobileTaskFollowUpView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let task: ProjectTask

    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        Form {
            Section {
                TextField("Ask the agent to change something…", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                    .focused($isFocused)
                    .accessibilityIdentifier("task-follow-up-text")
            } header: {
                Text(task.title)
            } footer: {
                Text("Continues the task's existing chat and moves it back into progress.")
            }
        }
        .navigationTitle("Follow-up")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSending {
                    ProgressView()
                } else {
                    Button("Send") { send() }
                        .disabled(!canSend)
                        .accessibilityIdentifier("task-follow-up-send")
                }
            }
        }
        .interactiveDismissDisabled(isSending)
        .mobileTaskErrorAlert($errorMessage)
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        let text = text
        Task {
            defer { isSending = false }
            do {
                try await state.sendTaskFollowUp(task, text: text)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
