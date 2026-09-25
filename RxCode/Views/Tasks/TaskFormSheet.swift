import RxCodeCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit sheet for a task or a story.
///
/// A new record can be written two ways, picked with the tabs at the top:
/// described once to the suggestion agent (AI), or filled in field by field
/// (Form). The kind — task or story — is a dropdown next to the tabs, so all
/// four combinations are reachable without reopening the sheet, and switching
/// keeps whatever has been drafted so far.
///
/// Edits a local draft and commits it on Save, so cancelling leaves the board
/// untouched. The agent block deliberately does *not* reuse `ModelPickerSheet` /
/// `EffortPickerSheet`: those write straight into `WindowState` session
/// overrides and cannot bind to a draft. It reuses their data sources instead.
struct TaskFormSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let payload: TaskBoardSheet
    let defaultProjectId: UUID
    /// The tab a new record opens on. `nil` keeps the per-kind default:
    /// stories are usually outlined from a description, tasks written directly.
    var initialMode: TaskCreationMode?

    @State private var isStory = false
    @State private var task = ProjectTask(projectId: UUID(), title: "")
    @State private var story = ProjectStory(projectId: UUID(), title: "")
    @State private var tagInput = ""
    @State private var showingAttachmentPicker = false
    @State private var isExistingRecord = false
    @State private var tab: Tab = .details
    /// A task opened from a story's Tasks section, edited in a nested form.
    @State private var childTask: TaskBoardSheet?
    /// The fields manager, opened scrolled to one section.
    @State private var fieldsSheet: TaskFieldsSheet.Field?
    @State private var versionInput = ""
    @State private var milestoneInput = ""
    @State private var isAutoFilling = false
    @State private var isGeneratingTitle = false
    @State private var suggestionAgent: TaskAgentConfig?
    @State private var pendingDeletion: TaskBoardSheet?
    @State private var creationMode: TaskCreationMode = .form
    /// The free-form description the AI tab drafts from. Shared by both kinds,
    /// so switching the kind dropdown re-uses what has already been typed.
    @State private var draftPrompt = ""
    @State private var storyTaskDrafts: [StoryTaskDraft] = []
    /// A task draft has been generated and is waiting to be reviewed. Tracked
    /// separately from the title, which the user may clear while editing.
    @State private var hasTaskDraft = false
    @State private var isGeneratingDraft = false
    @State private var showingSourceFilePicker = false
    @State private var draftError: String?

    private struct StoryTaskDraft: Identifiable {
        let id = UUID()
        var title: String
        var details: String
    }

    private enum Tab: Hashable {
        case details, run
    }

    /// A task that has been dispatched has a run to look at. Uses the stored
    /// task, so flipping the picker in this form doesn't swap tabs mid-edit.
    private var showsRunTab: Bool {
        guard isExistingRecord, !isStory, let stored = appState.task(id: task.id) else { return false }
        return stored.sessionKey != nil
    }

    /// Uses the stored task, not the draft, so changing the status picker in
    /// this form doesn't lock the field mid-edit.
    private var isDescriptionLocked: Bool {
        guard !isStory else { return false }
        return appState.task(id: task.id)?.isDescriptionLocked ?? false
    }

    private var isStatusLocked: Bool {
        guard let stored = appState.task(id: task.id) else { return false }
        return appState.isStatusLocked(stored)
    }

    /// The AI tab, which only exists while creating: an existing record has
    /// nothing left to draft.
    private var isComposing: Bool { !isExistingRecord && creationMode == .ai }

    private var canSave: Bool {
        let title = isStory ? story.title : task.title
        return !isAutoFilling && !isGeneratingTitle && !isGeneratingDraft
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isStory || storyTaskDrafts.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
    }

    /// Whether the reviewed draft in the AI tab can be committed.
    private var canCreateFromDraft: Bool {
        guard !isGeneratingDraft else { return false }
        if isStory {
            return !storyTaskDrafts.isEmpty
                && !story.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && storyTaskDrafts.allSatisfy {
                    !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        return hasTaskDraft && !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSuggestionInput: Bool {
        let title = isStory ? story.title : task.title
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !currentDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isExistingRecord {
                creationHeader
            } else if showsRunTab {
                Picker("View", selection: $tab) {
                    Text("Details").tag(Tab.details)
                    Text("Run").tag(Tab.run)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.top, 16)
                .padding(.bottom, 4)
            }

            if isComposing {
                draftComposer
            } else if showsRunTab, tab == .run {
                TaskRunView(taskId: task.id)
                    .frame(maxHeight: .infinity)
            } else {
                detailsForm
            }

            if isComposing {
                draftComposerFooter
            } else {
                footer
            }
        }
        .frame(width: 560, height: 680)
        .sheet(item: $childTask) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: story.projectId)
                .environment(appState)
                .environment(windowState)
        }
        .onAppear {
            loadDraft()
            suggestionAgent = appState.configuredTaskSuggestionAgent()
            // Open on the outcome: a task that has run is usually reopened to
            // see what the agent did.
            if showsRunTab { tab = .run }
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            switch candidate {
            case .task(let task): appState.deleteTask(task)
            case .story(let story): appState.deleteStory(story)
            }
            dismiss()
        }
        .fileImporter(
            isPresented: $showingSourceFilePicker,
            allowedContentTypes: [.plainText, .pdf]
        ) { result in
            importSourceFile(result)
        }
    }

    // MARK: - Creation header

    /// Kind on the left as a dropdown, mode on the right as tabs. Both stay
    /// live until the record is saved, and neither discards the other tab's
    /// work: the AI tab's draft *is* the form's draft.
    private var creationHeader: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: kindBinding) {
                Label("Task", systemImage: "checkmark.circle").tag(false)
                Label("Story", systemImage: "square.stack.3d.up").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(isGeneratingDraft || isAutoFilling || isGeneratingTitle)
            .help("Create a task or a story")
            .accessibilityIdentifier("task-form-kind")

            Spacer(minLength: 8)

            Picker("Mode", selection: $creationMode) {
                ForEach(TaskCreationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .disabled(isGeneratingDraft)
            .help("Describe it once and let the model draft it, or fill in the fields yourself")
            .accessibilityIdentifier("task-form-mode")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - AI tab

    private var draftComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isStory ? "Create Story with Tasks" : "Create Task")
                .font(.headline)

            Picker("Project", selection: projectBinding) {
                ForEach(appState.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }

            Text(isStory
                ? "Describe the story and tasks, or choose a text or PDF file."
                : "Describe the task, or choose a text or PDF file.")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            // The same editor the Form tab uses, so the source description
            // takes pasted and dropped images here too. A task keeps them in
            // its attachment list; a story has none, so they stay Markdown
            // links in the text the draft is generated from.
            MarkdownDescriptionEditor(
                text: $draftPrompt,
                attachments: isStory ? nil : $task.attachments,
                placeholder: isStory
                    ? String(localized: "Describe the story and the tasks it needs")
                    : String(localized: "Describe what needs doing"),
                height: 130,
                identifierPrefix: "story-create-prompt"
            )
            // An edited source makes the draft below stale, so it goes.
            .onChange(of: draftPrompt) { _, _ in clearGeneratedDraft() }

            HStack {
                Button("Choose File…") { showingSourceFilePicker = true }
                Spacer()
                Button {
                    Task { await generateDraft() }
                } label: {
                    if isGeneratingDraft { ProgressView().controlSize(.small) }
                    else { Label("Generate Draft", systemImage: "sparkles") }
                }
                .disabled(isGeneratingDraft || draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("story-create-generate")
            }

            if let draftError {
                Text(draftError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if isStory {
                if !storyTaskDrafts.isEmpty { storyDraftPreview }
            } else if hasTaskDraft {
                taskDraftPreview
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var storyDraftPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            TextField("Story title", text: $story.title)
                .accessibilityIdentifier("story-create-title")
            Text("Tasks")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    storyTaskDraftRows
                }
            }
            Button("Add Task") { storyTaskDrafts.append(StoryTaskDraft(title: "", details: "")) }
        }
    }

    /// The generated task, editable before it is saved. Only the fields worth
    /// correcting in place are here — the Form tab has the rest, and switching
    /// to it carries this draft over untouched.
    private var taskDraftPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            TextField("Task title", text: $task.title)
                .accessibilityIdentifier("task-create-title")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Task details", text: $task.details, axis: .vertical)
                        .lineLimit(3...12)
                    draftPropertyChips
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What the model filled in, as read-only chips: the Form tab is one tap
    /// away for changing any of them.
    @ViewBuilder
    private var draftPropertyChips: some View {
        let chips = suggestedProperties
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested properties")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                FlowLayout(spacing: 4) {
                    ForEach(chips, id: \.text) { chip in
                        TaskBoardChipLabel(icon: chip.icon, title: chip.text, isActive: true)
                    }
                }
            }
        }
    }

    private var suggestedProperties: [(icon: String, text: String)] {
        var chips: [(icon: String, text: String)] = []
        if let type = board.itemType(id: task.typeId) {
            chips.append((icon: "circle.fill", text: type.name))
        }
        if let priority = task.priority {
            chips.append((icon: priority.systemImage, text: String(localized: priority.displayName)))
        }
        if let parent = board.story(id: task.storyId) {
            chips.append((icon: "square.stack.3d.up", text: parent.title))
        }
        if let version = task.version, !version.isEmpty {
            chips.append((icon: "tag", text: version))
        }
        if let milestone = task.milestone, !milestone.isEmpty {
            chips.append((icon: "flag", text: milestone))
        }
        chips += task.tags.map { (icon: "number", text: $0) }
        return chips
    }

    private var storyTaskDraftRows: some View {
        ForEach($storyTaskDrafts) { $draft in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    TextField("Task title", text: $draft.title)
                    Button {
                        storyTaskDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove task")
                }
                TextField("Task details", text: $draft.details, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private var draftComposerFooter: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isStory ? "Create Story and Tasks" : "Create Task") {
                if isStory { saveComposedStory() } else { save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreateFromDraft)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(isStory ? "story-create-save" : "task-create-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var detailsForm: some View {
        Form {
            detailsSection
            if isStory {
                storyTasksSection
            }
            classificationSection
            tagsSection
            if !isStory {
                agentSection
                attachmentsSection
            }
        }
        .formStyle(.grouped)
        .sheet(item: $fieldsSheet) { field in
            TaskFieldsSheet(projectId: currentProjectId, initialField: field)
                .environment(appState)
        }
        // Effort levels are provider-dependent and fetched at runtime, so reload
        // them whenever the picked provider changes and drop an effort the new
        // provider doesn't accept.
        .task(id: task.agent.provider) {
            let provider = task.agent.provider ?? appState.selectedAgentProvider
            await appState.loadReasoningLevels(for: provider)
            if let effort = task.agent.effort {
                task.agent.effort = await appState.sanitizedEffort(effort, for: provider)
            }
        }
        .fileImporter(
            isPresented: $showingAttachmentPicker,
            // Any file, not just images: the description can reference
            // anything, and the agent reads text files straight off disk.
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleAttachmentImport(result)
        }
    }

    // MARK: - Footer

    private var headerTitle: String {
        if isExistingRecord { return isStory ? "Edit Story" : "Edit Task" }
        return isStory ? "New Story" : "New Task"
    }

    private var footer: some View {
        HStack {
            if isExistingRecord {
                Button("Delete", role: .destructive) {
                    pendingDeletion = isStory ? .story(story) : .task(task)
                }
            }
            if isExistingRecord, !isStory, appState.canOpenChat(for: task) {
                Button("Open Chat") {
                    dismiss()
                    appState.openChat(for: task, in: windowState)
                }
                .help("Open the thread this task ran in")
            }
            if isExistingRecord, !isStory, let savedTask = appState.task(id: task.id) {
                Button {
                    dismiss()
                    windowState.taskDetailProjectId = savedTask.projectId
                    windowState.generalRoute = .tasks
                } label: {
                    Label("Jump to Project", systemImage: "folder")
                }
                .help("Open this task's project page")
                .accessibilityIdentifier("task-form-jump-to-project")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section(LocalizedStringKey(headerTitle)) {
            HStack(spacing: 6) {
                TextField(
                    "Title",
                    text: isStory ? $story.title : $task.title,
                    prompt: Text(isStory ? "Story title" : "What needs doing?")
                )
                // Grouped forms right-align fields, and a right-aligned field
                // hides a trailing space until the next character is typed, so
                // typing a space looked like it did nothing. Leading alignment
                // shows it immediately.
                .multilineTextAlignment(.leading)

                Button(action: generateTitle) {
                    if isGeneratingTitle {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isGeneratingTitle || isAutoFilling || currentDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Write the title from the description")
                .accessibilityLabel("Generate Title")
                .accessibilityIdentifier("task-form-generate-title")
            }

            MarkdownDescriptionEditor(
                text: isStory ? $story.details : $task.details,
                // Stories keep no attachment list, so a file dropped on a story
                // description is recorded as a Markdown link only.
                attachments: isStory ? nil : $task.attachments,
                placeholder: String(localized: "Add more detail for the agent"),
                isDisabled: isDescriptionLocked
            )

            if isDescriptionLocked {
                Label("The description is locked once a task leaves Pending, so it keeps matching what the agent was asked to do.", systemImage: "lock")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Picker("Project", selection: projectBinding) {
                ForEach(appState.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
        }
    }

    /// Shows unsaved generated tasks in the form before they are committed.
    private var storyTasksSection: some View {
        Section {
            if !isExistingRecord && !storyTaskDrafts.isEmpty {
                storyTaskDraftRows
                Button("Add Task") {
                    storyTaskDrafts.append(StoryTaskDraft(title: "", details: ""))
                }
                .accessibilityIdentifier("story-form-add-draft-task")
            }

            let existing = isExistingRecord
                ? appState.taskBoard(for: story.projectId).tasks(inStory: story.id).sorted { $0.sortIndex < $1.sortIndex }
                : []
            ForEach(existing) { task in
                Button {
                    childTask = .task(task)
                } label: {
                    HStack(spacing: 8) {
                        TaskStatusIcon(status: task.status, board: board, size: 12)
                        Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(board.column(for: task.status).name)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExistingRecord || storyTaskDrafts.isEmpty {
                Button(action: newStoryTask) {
                    Label("New Task…", systemImage: "plus")
                }
                .disabled(!canSave)
                .accessibilityIdentifier("story-form-new-task")
            }
        } header: {
            Text("Tasks")
        } footer: {
            if !isExistingRecord && storyTaskDrafts.isEmpty {
                Text("Adding a task saves this story first, so the task has a story to belong to.")
            }
        }
    }

    private var currentProjectId: UUID { isStory ? story.projectId : task.projectId }
    private var currentDetails: String { isStory ? story.details : task.details }
    private var board: TaskBoard { appState.taskBoard(for: currentProjectId) }

    /// The task's column, normalized so a status whose column was deleted
    /// still selects a picker row.
    private var statusBinding: Binding<TaskStatus> {
        Binding(
            get: { board.resolvedStatus(of: task) },
            set: { task.status = $0 }
        )
    }

    private var classificationSection: some View {
        Section {
            LabeledContent("AI suggestions model") {
                Menu {
                    Button("Default task agent") { selectSuggestionAgent(nil) }
                    Divider()
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section(section.title) {
                            ForEach(section.models, id: \.key) { model in
                                Button(model.displayName) {
                                    selectSuggestionAgent(TaskAgentConfig(provider: model.provider, model: model.id))
                                }
                            }
                        }
                    }
                } label: {
                    TaskBoardChipLabel(
                        icon: "sparkles",
                        title: suggestionAgent.map(appState.taskAgentLabel) ?? String(localized: "Default task agent"),
                        isActive: suggestionAgent != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isAutoFilling || isGeneratingTitle)
            }

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
                    autoFill()
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
                .help("Ask the selected model to fill in empty properties")
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

    /// Types are picked from a dropdown; adding, renaming and recoloring
    /// happen in the fields sheet so every story and task shares one list.
    private var typeMenu: some View {
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

    private var tagsSection: some View {
        let tags = isStory ? story.tags : task.tags
        let unused = board.allTags.filter { !tags.contains($0) }
        return Section {
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
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        TaskRemovableChip(text: tag, tint: board.tint(forTag: tag)) {
                            removeTag(tag)
                        }
                    }
                }
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

    private var agentSection: some View {
        Section {
            LabeledContent("Model") {
                Menu {
                    Button("Unassigned") {
                        task.agent.provider = nil
                        task.agent.model = nil
                    }
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section(section.title) {
                            ForEach(section.models, id: \.key) { model in
                                Button(model.displayName) {
                                    task.agent.provider = model.provider
                                    task.agent.model = model.id
                                    appState.rememberTaskAgentModel(provider: model.provider, model: model.id)
                                }
                            }
                        }
                    }
                } label: {
                    TaskBoardChipLabel(
                        icon: "sparkles",
                        title: modelMenuTitle,
                        isActive: task.agent.isAssigned
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            effortPicker

            Picker("Permission Mode", selection: permissionBinding) {
                Text("Default").tag(PermissionMode?.none)
                // `.plan` is excluded here on purpose: plan mode is the separate
                // toggle below, matching every other permission picker in the app.
                ForEach(PermissionMode.allCases.filter { $0 != .plan }, id: \.self) { mode in
                    Text(mode.displayName).tag(PermissionMode?.some(mode))
                }
            }

            Toggle("Plan mode", isOn: $task.agent.planMode)
                .help("Run the agent with --permission-mode plan so it proposes a plan before editing")
        } header: {
            Text("Agent")
        } footer: {
            Text("Dropping this task into In Progress runs the assigned agent in a new thread. It moves to Pending Review when the turn finishes.")
        }
    }

    @ViewBuilder
    private var effortPicker: some View {
        let provider = task.agent.provider ?? appState.selectedAgentProvider
        let levels = appState.reasoningLevels(for: provider)
        // ACP clients expose no reasoning levels, so the picker hides itself
        // rather than showing an empty menu.
        if !levels.isEmpty {
            Picker("Thinking Level", selection: $task.agent.effort) {
                Text(appState.defaultEffortTitle(for: provider)).tag(String?.none)
                ForEach(levels) { level in
                    Text(level.displayName).tag(String?.some(level.id))
                }
            }
        }
    }

    private var attachmentsSection: some View {
        Section {
            if !task.attachments.isEmpty {
                ForEach(task.attachments, id: \.id) { dto in
                    HStack(spacing: 6) {
                        Image(systemName: dto.type == Attachment.AttachmentType.image.rawValue ? "photo" : "doc")
                            .foregroundStyle(ClaudeTheme.textSecondary)
                        Text(dto.name)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            task.attachments.removeAll { $0.id == dto.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ClaudeTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                }
            }

            Button {
                showingAttachmentPicker = true
            } label: {
                Label("Add Files…", systemImage: "paperclip")
            }
        } header: {
            Text("Attachments")
        } footer: {
            Text("Files pasted or dropped into the description are listed here and sent to the agent with the task.")
        }
    }

    // MARK: - Small builders

    private var modelMenuTitle: String {
        guard let model = task.agent.model, !model.isEmpty else {
            return task.agent.provider?.displayNameText ?? String(localized: "Unassigned")
        }
        return appState.modelDisplayLabel(model, provider: task.agent.provider ?? .claudeCode)
    }

    // MARK: - Bindings

    private var projectBinding: Binding<UUID> {
        Binding(
            get: { isStory ? story.projectId : task.projectId },
            set: { newValue in
                if isStory {
                    story.projectId = newValue
                } else {
                    task.projectId = newValue
                    // A story belongs to one project, so a project change drops
                    // a parent that no longer exists in scope.
                    task.storyId = nil
                }
            }
        )
    }

    private var storyBinding: Binding<UUID?> {
        Binding(get: { task.storyId }, set: { task.storyId = $0 })
    }

    /// Kind is only switchable before the record exists — converting a story
    /// into a task (or back) would orphan children or lose the agent
    /// assignment. The two drafts are separate, so nothing typed is lost;
    /// only the generated outline, which belongs to the kind it was made for.
    private var kindBinding: Binding<Bool> {
        Binding(
            get: { isStory },
            set: { newValue in
                guard newValue != isStory else { return }
                // Keep the record in the project the other kind was pointed at.
                let projectId = isStory ? story.projectId : task.projectId
                isStory = newValue
                projectBinding.wrappedValue = projectId
                if !newValue {
                    // The task draft may never have been set up: it is only
                    // prepared on load when the sheet opened on a task.
                    task.status = appState.taskBoard(for: projectId).firstColumn.id
                    if !task.agent.isAssigned {
                        let fallback = appState.defaultTaskAgent()
                        task.agent.provider = fallback.provider
                        task.agent.model = fallback.model
                    }
                }
                clearGeneratedDraft()
            }
        )
    }

    /// A field shared by stories and tasks, bound to whichever the form edits.
    private func field<Value>(
        _ taskPath: WritableKeyPath<ProjectTask, Value>,
        _ storyPath: WritableKeyPath<ProjectStory, Value>
    ) -> Binding<Value> {
        Binding(
            get: { isStory ? story[keyPath: storyPath] : task[keyPath: taskPath] },
            set: { newValue in
                if isStory {
                    story[keyPath: storyPath] = newValue
                } else {
                    task[keyPath: taskPath] = newValue
                }
            }
        )
    }

    private var permissionBinding: Binding<PermissionMode?> {
        Binding(get: { task.agent.permissionMode }, set: { task.agent.permissionMode = $0 })
    }

    // MARK: - Actions

    private func generateDraft() async {
        if isStory {
            await generateStoryDraft()
        } else {
            await generateTaskDraft()
        }
    }

    private func generateStoryDraft() async {
        let source = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let projectId = story.projectId
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }
        let draft = await appState.suggestStoryDraft(source: String(source.prefix(30_000)), projectId: projectId)
        guard isStory, draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == source,
              story.projectId == projectId else { return }
        guard let draft else {
            let title = TaskTitleSuggestion.fallback(from: source)
            story.title = title
            story.details = source
            storyTaskDrafts = [StoryTaskDraft(title: title, details: source)]
            draftError = String(localized: "The suggestion agent did not respond. Review this single-task draft before creating it.")
            return
        }
        story.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        story.details = source
        storyTaskDrafts = draft.tasks.prefix(12).map {
            StoryTaskDraft(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                           details: $0.details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Turns the description into a reviewable task: the source stays the
    /// description — it is what the agent is eventually asked to do — and the
    /// model writes the title and fills the empty properties, the same two
    /// calls quick add makes in the background.
    private func generateTaskDraft() async {
        let source = String(draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30_000))
        guard !source.isEmpty else { return }
        let projectId = task.projectId
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }

        var candidate = task
        candidate.details = source
        candidate.title = ""
        // Independent prompts: run them together rather than paying for two
        // round trips in a row.
        async let suggestedTitle = appState.suggestTitle(details: source, storyTitle: nil, projectId: projectId)
        async let classification = appState.suggestClassification(for: candidate)
        let (title, suggestion) = await (suggestedTitle, classification)

        guard !isStory, draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30_000) == source,
              task.projectId == projectId else { return }
        task.details = source
        task.title = title ?? TaskTitleSuggestion.fallback(from: source)
        suggestion?.apply(to: &task, board: board)
        hasTaskDraft = true
        if title == nil, suggestion == nil {
            draftError = String(localized: "The suggestion agent did not respond. Review this draft before creating it.")
        }
    }

    /// Drops what the model produced, keeping the source text: the outline
    /// belongs to the description it was generated from, and to the kind it
    /// was generated for.
    private func clearGeneratedDraft() {
        storyTaskDrafts = []
        hasTaskDraft = false
        draftError = nil
    }

    private func importSourceFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { draftError = error.localizedDescription }
            return
        }
        Task {
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    try DraftSourceFile.read(url)
                }.value
                let heading = "# \(url.lastPathComponent)\n\n"
                draftPrompt += (draftPrompt.isEmpty ? "" : "\n\n") + heading + content
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    private func saveComposedStory() {
        guard !storyTaskDrafts.isEmpty else { return }
        story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !story.title.isEmpty,
              storyTaskDrafts.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return }
        appState.upsertStory(story)
        for draft in storyTaskDrafts {
            var task = appState.newTaskDraft(inStory: story)
            task.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            task.details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
            task.agent = appState.defaultTaskAgent()
            appState.upsertTask(task)
        }
        dismiss()
    }

    private func loadDraft() {
        switch payload {
        case .task(let incoming):
            isStory = false
            task = incoming
            isExistingRecord = appState.task(id: incoming.id) != nil
            if appState.projects.allSatisfy({ $0.id != task.projectId }) {
                task.projectId = defaultProjectId
            }
            // A new task starts on the last model picked, so it's ready to run.
            if !isExistingRecord, !task.agent.isAssigned {
                let fallback = appState.defaultTaskAgent()
                task.agent.provider = fallback.provider
                task.agent.model = fallback.model
            }
        case .story(let incoming):
            isStory = true
            story = incoming
            isExistingRecord = appState.stories().contains { $0.id == incoming.id }
            if appState.projects.allSatisfy({ $0.id != story.projectId }) {
                story.projectId = defaultProjectId
            }
        }
        creationMode = .resolved(
            isExistingRecord: isExistingRecord,
            isStory: isStory,
            requested: initialMode
        )
    }

    /// Opens a blank task form assigned to this story. A story that hasn't
    /// been saved yet is saved first — the task needs an existing parent, and
    /// the story form stays open for further edits.
    private func newStoryTask() {
        if !isExistingRecord {
            story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertStory(story)
            isExistingRecord = true
        }
        childTask = .task(appState.newTaskDraft(inStory: story))
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        tagInput = ""
        guard !trimmed.isEmpty else { return }
        // Reuse the board's spelling of a label that differs only by case.
        appendTag(board.allTags.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed)
    }

    private func appendTag(_ tag: String) {
        tagInput = ""
        if isStory {
            if !story.tags.contains(tag) { story.tags.append(tag) }
        } else {
            if !task.tags.contains(tag) { task.tags.append(tag) }
        }
    }

    private func removeTag(_ tag: String) {
        if isStory {
            story.tags.removeAll { $0 == tag }
        } else {
            task.tags.removeAll { $0 == tag }
        }
    }

    /// Summarizes the draft's description into a title. Unlike auto-fill this
    /// does overwrite — it is only reachable by pressing the button, and the
    /// point of pressing it is to replace whatever the title says now.
    private func generateTitle() {
        guard !isGeneratingTitle, !isAutoFilling else { return }
        let details = currentDetails
        let wasStory = isStory
        let itemId = wasStory ? story.id : task.id
        let projectId = currentProjectId
        let parentTitle = wasStory ? nil : board.story(id: task.storyId)?.title
        isGeneratingTitle = true
        Task {
            defer { isGeneratingTitle = false }
            guard let title = await appState.suggestTitle(details: details, storyTitle: parentTitle, projectId: projectId) else { return }
            guard isStory == wasStory, (wasStory ? story.id : task.id) == itemId,
                  currentProjectId == projectId else { return }
            if wasStory {
                story.title = title
            } else {
                task.title = title
            }
        }
    }

    /// Fills the draft's empty properties from the selected suggestion model. The
    /// draft is only filled, never overwritten, and nothing is saved until
    /// the user presses Save.
    private func autoFill() {
        guard !isAutoFilling, !isGeneratingTitle else { return }
        // Unconfirmed combo-box text is still a user choice and must win.
        if let version = TaskSingleValueCombo.resolve(versionInput, in: board.allVersions) {
            field(\.version, \.version).wrappedValue = version
        }
        if let milestone = TaskSingleValueCombo.resolve(milestoneInput, in: board.allMilestones) {
            field(\.milestone, \.milestone).wrappedValue = milestone
        }
        isAutoFilling = true
        let wasStory = isStory
        let storyDraft = story
        let taskDraft = task
        Task {
            defer { isAutoFilling = false }
            let suggestion: TaskClassification?
            if wasStory {
                suggestion = await appState.suggestClassification(for: storyDraft)
            } else {
                suggestion = await appState.suggestClassification(for: taskDraft)
            }
            guard let suggestion, isStory == wasStory else { return }
            if wasStory, story.id == storyDraft.id, story.projectId == storyDraft.projectId {
                suggestion.apply(to: &story, board: board)
            } else if !wasStory, task.id == taskDraft.id, task.projectId == taskDraft.projectId {
                suggestion.apply(to: &task, board: board)
            }
        }
    }

    private func selectSuggestionAgent(_ agent: TaskAgentConfig?) {
        appState.setConfiguredTaskSuggestionAgent(agent)
        suggestionAgent = agent
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard let attachment = AttachmentFactory.fromFileURL(url) else { continue }
            let dto = attachment.persistableInTaskBoard().dto
            guard !task.attachments.contains(where: { $0.path == dto.path }) else { continue }
            task.attachments.append(dto)
        }
    }

    private func save() {
        guard canSave else { return }
        // Values typed but not yet confirmed with Return still count.
        if let version = TaskSingleValueCombo.resolve(versionInput, in: board.allVersions) {
            field(\.version, \.version).wrappedValue = version
        }
        if let milestone = TaskSingleValueCombo.resolve(milestoneInput, in: board.allMilestones) {
            field(\.milestone, \.milestone).wrappedValue = milestone
        }
        if !tagInput.trimmingCharacters(in: .whitespaces).isEmpty {
            addTag()
        }
        if isStory {
            if !storyTaskDrafts.isEmpty {
                saveComposedStory()
                return
            }
            story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertStory(story)
        } else {
            task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertTask(task)
        }
        dismiss()
    }
}

private enum DraftSourceFile {
    nonisolated static func read(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else {
            throw DraftSourceFileError.tooLarge
        }
        let content: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw DraftSourceFileError.unreadable }
            content = document.string ?? ""
        } else {
            content = try String(contentsOf: url, encoding: .utf8)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftSourceFileError.empty }
        return String(trimmed.prefix(30_000))
    }
}

private enum DraftSourceFileError: LocalizedError {
    case tooLarge, unreadable, empty

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "The selected file is too large (20 MB maximum).")
        case .unreadable: String(localized: "Could not read the selected file.")
        case .empty: String(localized: "The selected file contains no readable text.")
        }
    }
}
