import RxCodeChatKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit sheet for a task or a story.
///
/// A new record can be written two ways: described once to the suggestion
/// agent (AI), or filled in field by field (Form). The kind and the mode are
/// both picked from the add menu that opens the sheet, so the sheet itself
/// shows only the one flow asked for.
///
/// Edits a local draft and commits it on Save, so cancelling leaves the board
/// untouched. The agent block deliberately does *not* reuse `ModelPickerSheet` /
/// `EffortPickerSheet`: those write straight into `WindowState` session
/// overrides and cannot bind to a draft. It reuses their data sources instead.
struct TaskFormSheet: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState
    @Environment(\.dismiss) var dismiss

    let payload: TaskBoardSheet
    let defaultProjectId: UUID

    @State private var cloudDevices: [CloudDevice] = []
    @State private var cloudDeviceError: String?
    @State var isStory = false
    @State var task = ProjectTask(projectId: UUID(), title: "")
    @State var story = ProjectStory(projectId: UUID(), title: "")
    @State var tagInput = ""
    @State var showingAttachmentPicker = false
    @State var isExistingRecord = false
    @State var tab: Tab = .details
    @State var followUpDraft = ""
    @State var followUpAttachments: [Attachment] = []
    @State private var pendingExit: ExitAction?
    @State private var showingDiscardFollowUpConfirmation = false
    /// A task opened from a story's Tasks section, edited in a nested form.
    @State var childTask: TaskBoardSheet?
    /// The fields manager, opened scrolled to one section.
    @State var fieldsSheet: TaskFieldsSheet.Field?
    @State var versionInput = ""
    @State var milestoneInput = ""
    @State var isAutoFilling = false
    @State var isGeneratingTitle = false
    @State var suggestionAgent: GeneralAIModel = .taskAgent
    @State var pendingDeletion: TaskBoardSheet?
    @State var creationMode: TaskCreationMode = .form
    /// The free-form description the AI flow drafts from.
    @State var draftPrompt = ""
    @State var storyTaskDrafts: [StoryTaskDraft] = []
    /// The model every task of a drafted story is assigned to.
    @State var storyDraftAgent = TaskAgentConfig()
    /// A generated story task being added or edited in its own sheet.
    @State var editingStoryTaskDraft: StoryTaskDraft?
    /// A task draft has been generated and is waiting to be reviewed. Tracked
    /// separately from the title, which the user may clear while editing.
    @State var hasTaskDraft = false
    @State var isGeneratingDraft = false
    @State var showingSourceFilePicker = false
    @State var draftError: String?
    /// The AI flow's step: write the description, then review what the model
    /// drafted from it. Revising goes back without dropping the draft; only
    /// editing the description does that.
    @State var draftStep: DraftStep = .describe

    struct StoryTaskDraft: Identifiable {
        let id = UUID()
        var title: String
        var details: String
        /// The draft that must finish before this one starts, saved as the
        /// created task's "Starts after" link.
        var startsAfter: UUID?
    }

    enum Tab: Hashable {
        case details, run
    }

    private enum ExitAction {
        case cancel, save, openChat, jumpToProject
    }

    enum DraftStep {
        case describe, review
    }

    /// Whether the model has produced something to review.
    var hasGeneratedDraft: Bool {
        isStory ? !storyTaskDrafts.isEmpty : hasTaskDraft
    }

    var canGenerateDraft: Bool {
        !isGeneratingDraft && !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A task that has been dispatched has a run to look at. Uses the stored
    /// task, so flipping the picker in this form doesn't swap tabs mid-edit.
    var storedAttentionReason: String? {
        guard isExistingRecord, !isStory else { return nil }
        return appState.task(id: task.id)?.attentionReason
    }

    var showsRunTab: Bool {
        guard isExistingRecord, !isStory, let stored = appState.task(id: task.id) else { return false }
        return stored.sessionKey != nil
    }

    /// Uses the stored task, not the draft, so changing the status picker in
    /// this form doesn't lock the field mid-edit.
    var isDescriptionLocked: Bool {
        guard !isStory else { return false }
        return appState.task(id: task.id)?.isDescriptionLocked ?? false
    }

    var isStatusLocked: Bool {
        guard let stored = appState.task(id: task.id) else { return false }
        return appState.isStatusLocked(stored)
    }

    /// The AI flow, which only exists while creating: an existing record has
    /// nothing left to draft.
    var isComposing: Bool { !isExistingRecord && creationMode == .ai }

    var canSave: Bool {
        let title = isStory ? story.title : task.title
        return !isAutoFilling && !isGeneratingTitle && !isGeneratingDraft
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isStory || storyTaskDrafts.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
    }

    /// Whether the reviewed draft in the AI tab can be committed.
    var canCreateFromDraft: Bool {
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

    var hasSuggestionInput: Bool {
        let title = isStory ? story.title : task.title
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !currentDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsRunTab {
                ZStack(alignment: .topLeading) {
                    Picker("View", selection: $tab) {
                        Text("Details").tag(Tab.details)
                        Text("Run").tag(Tab.run)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)

                    // Keep the badge beside the Run label, inside its segment.
                    if storedAttentionReason != nil {
                        Circle()
                            .fill(ClaudeTheme.statusWarning)
                            .frame(width: 8, height: 8)
                            .offset(x: 184, y: 5)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Run needs attention")
                            .accessibilityIdentifier("task-form-run-attention-badge")
                    }
                }
                .frame(width: 220)
                .padding(.top, 16)
                .padding(.bottom, 4)
            }

            // Read from the stored task: the draft is a copy taken on open and
            // wouldn't pick up a verification that fails while the sheet is up.
            // When there's a Run tab, the transcript shows it as its last
            // message and the segment gets a badge instead.
            if !showsRunTab, let reason = storedAttentionReason {
                TaskAttentionBanner(reason: reason)
                    .padding(.horizontal, 20)
                    .padding(.top, showsRunTab ? 8 : 16)
            }

            if isComposing {
                draftComposer
            } else if showsRunTab, tab == .run {
                TaskRunView(
                    taskId: task.id,
                    followUp: $followUpDraft,
                    followUpAttachments: $followUpAttachments,
                    onOpenChat: { requestExit(.openChat) }
                )
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
        .confirmationDialog(
            "Discard follow-up?",
            isPresented: $showingDiscardFollowUpConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Follow-up", role: .destructive) {
                if let pendingExit { performExit(pendingExit) }
                pendingExit = nil
            }
            Button("Keep Editing", role: .cancel) { pendingExit = nil }
        } message: {
            Text("There is unsent content in the follow-up field. Are you sure you want to discard it?")
        }
        .sheet(item: $childTask) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: currentProjectId)
                .environment(appState)
                .environment(windowState)
        }
        .onAppear {
            loadDraft()
            if isExistingRecord {
                AnalyticsService.shared.log(isStory ? .projectStoryOpened : .projectTaskOpened)
                // Retarget the toolbar (run, terminal, diff) at the opened
                // task's project while browsing the Projects board.
                if windowState.showingTasks {
                    appState.focusProject(id: currentProjectId, in: windowState)
                }
            }
            suggestionAgent = appState.generalAIModel()
            // Open on the outcome: a task that has run is usually reopened to
            // see what the agent did.
            if showsRunTab { tab = .run }
        }
        .taskDeletionConfirmation(pending: $pendingDeletion) { candidate in
            switch candidate {
            case .task(let task, _): appState.deleteTask(task)
            case .story(let story, _): appState.deleteStory(story)
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

    var detailsForm: some View {
        Form {
            detailsSection
            if isStory {
                storyTasksSection
            } else if isExistingRecord && !linkedChildren.isEmpty {
                linkedTasksSection
            }
            classificationSection
            tagsSection
            if !isStory {
                if appState.projects.first(where: { $0.id == currentProjectId })?.isCloud == true {
                    Section("Assigned Mac") {
                        Picker("Laptop", selection: $task.assignedDeviceId) {
                            Text("Unassigned").tag(String?.none)
                            ForEach(cloudDevices) { Text($0.name).tag(Optional($0.id)) }
                            if let id = task.assignedDeviceId, !cloudDevices.contains(where: { $0.id == id }) {
                                Text("Previously assigned Mac").tag(Optional(id))
                            }
                        }
                        if let cloudDeviceError { Text(cloudDeviceError).foregroundStyle(.red) }
                    }
                    .task {
                        do { cloudDevices = try await appState.projectCloud.listDevices() }
                        catch { cloudDeviceError = error.localizedDescription }
                    }
                }
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

    var headerTitle: String {
        if isExistingRecord { return isStory ? "Edit Story" : "Edit Task" }
        return isStory ? "New Story" : "New Task"
    }

    var footer: some View {
        HStack {
            if isExistingRecord {
                Button("Delete", role: .destructive) {
                    pendingDeletion = isStory ? .story(story) : .task(task)
                }
            }
            if isExistingRecord, !isStory, appState.canOpenChat(for: task) {
                Button("Open Chat") { requestExit(.openChat) }
                .help("Open the thread this task ran in")
            }
            if isExistingRecord, !isStory, appState.task(id: task.id) != nil {
                Button {
                    requestExit(.jumpToProject)
                } label: {
                    Label("Jump to Project", systemImage: "folder")
                }
                .help("Open this task's project page")
                .accessibilityIdentifier("task-form-jump-to-project")
            }
            Spacer()
            Button("Cancel") { requestExit(.cancel) }
                .keyboardShortcut(.cancelAction)
            Button("Save") { requestExit(.save) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var hasUnsentFollowUp: Bool {
        !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpAttachments.isEmpty
    }

    private func requestExit(_ action: ExitAction) {
        guard hasUnsentFollowUp else {
            performExit(action)
            return
        }
        pendingExit = action
        showingDiscardFollowUpConfirmation = true
    }

    private func performExit(_ action: ExitAction) {
        switch action {
        case .cancel:
            dismiss()
        case .save:
            save()
        case .openChat:
            dismiss()
            appState.openChat(for: task, in: windowState)
        case .jumpToProject:
            guard let savedTask = appState.task(id: task.id) else { return }
            dismiss()
            windowState.taskDetailProjectId = savedTask.projectId
            windowState.generalRoute = .tasks
        }
    }

    // MARK: - Sections

    var detailsSection: some View {
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
            // A saved story moves between projects by sharing, so each linked
            // board keeps its copy and tasks instead of being duplicated.
            .disabled(isStory && isExistingRecord)
            .help(isStory && isExistingRecord ? "Use Shared With to add this story to other projects" : "")

            if isStory, appState.projects.count > 1 {
                sharedProjectsMenu
            }
        }
    }

    /// Other projects this story is shared with. Each linked project's board
    /// shows the story, and its tasks there can join it.
    var sharedProjectsMenu: some View {
        let others = appState.projects.filter { $0.id != story.projectId }
        let linked = others.filter { story.linkedProjectIds.contains($0.id) }
        let title: String = switch linked.count {
        case 0: String(localized: "Only this project")
        case 1: linked[0].name
        default: String(localized: "\(linked.count) projects")
        }
        return LabeledContent("Shared With") {
            Menu {
                ForEach(others) { project in
                    Toggle(project.name, isOn: linkBinding(for: project.id))
                }
            } label: {
                TaskBoardChipLabel(icon: "link", title: title, isActive: !linked.isEmpty)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show this story on other projects' boards")
            .accessibilityIdentifier("story-form-shared-projects")
        }
    }

    var storyTasksSection: some View {
        Section {
            // Tasks from every project the saved story is shared with.
            let stored = isExistingRecord ? appState.taskBoard(for: story.projectId).story(id: story.id) : nil
            let existing = stored.map { appState.tasks(inStory: $0).sorted { $0.sortIndex < $1.sortIndex } } ?? []
            let showsProject = stored?.isShared ?? false
            ForEach(existing) { task in
                let taskBoard = appState.taskBoard(for: task.projectId)
                Button {
                    childTask = .task(task)
                } label: {
                    HStack(spacing: 8) {
                        TaskStatusIcon(status: task.status, board: taskBoard, size: 12)
                        Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if showsProject, let project = appState.projects.first(where: { $0.id == task.projectId }) {
                            Text(project.name)
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Text(taskBoard.column(for: task.status).name)
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

            Button(action: newStoryTask) {
                Label("New Task…", systemImage: "plus")
            }
            .disabled(!canSave)
            .accessibilityIdentifier("story-form-new-task")
        } header: {
            Text("Tasks")
        } footer: {
            if !isExistingRecord {
                Text("Adding a task saves this story first, so the task has a story to belong to.")
            }
        }
    }

    var linkedTasksSection: some View {
        Section("Linked Tasks") {
            ForEach(linkedChildren) { child in
                Button {
                    childTask = .task(child)
                } label: {
                    HStack {
                        TaskStatusIcon(status: child.status, board: appState.taskBoard(for: child.projectId), size: 12)
                        Text(child.title)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Tasks in any project that start after this one.
    var linkedChildren: [ProjectTask] {
        appState.allTasks().filter { $0.parentTaskIds.contains(task.id) }
    }

    var currentProjectId: UUID { isStory ? story.projectId : task.projectId }
    var currentDetails: String { isStory ? story.details : task.details }
    var board: TaskBoard { appState.taskBoard(for: currentProjectId) }

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
            LabeledContent("AI model") {
                SuggestionAgentMenu(agent: $suggestionAgent)
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

    var agentSection: some View {
        Section {
            LabeledContent("Model") {
                agentModelMenu($task.agent)
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
    var effortPicker: some View {
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

    var attachmentsSection: some View {
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

    /// The model chip shared by the form's agent section and the AI flow's
    /// review step. Picking a model remembers it for the next new task.
    func agentModelMenu(_ agent: Binding<TaskAgentConfig>) -> some View {
        Menu {
            Button("Unassigned") {
                agent.wrappedValue.provider = nil
                agent.wrappedValue.model = nil
            }
            ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { model in
                        Button(model.displayName) {
                            agent.wrappedValue.provider = model.provider
                            agent.wrappedValue.model = model.id
                            appState.rememberTaskAgentModel(provider: model.provider, model: model.id)
                        }
                    }
                }
            }
        } label: {
            TaskBoardChipLabel(
                icon: "sparkles",
                title: modelMenuTitle(for: agent.wrappedValue),
                isActive: agent.wrappedValue.isAssigned
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    func modelMenuTitle(for agent: TaskAgentConfig) -> String {
        guard let model = agent.model, !model.isEmpty else {
            return agent.provider?.displayNameText ?? String(localized: "Unassigned")
        }
        return appState.modelDisplayLabel(model, provider: agent.provider ?? .claudeCode)
    }

    // MARK: - Bindings

    var projectBinding: Binding<UUID> {
        Binding(
            get: { isStory ? story.projectId : task.projectId },
            set: { newValue in
                if isStory {
                    story.projectId = newValue
                    story.linkedProjectIds.removeAll { $0 == newValue }
                } else {
                    task.projectId = newValue
                    // A story belongs to one project, so a project change drops
                    // it. A parent may be in any project, so it stays.
                    task.storyId = nil
                }
            }
        )
    }

    func linkBinding(for projectId: UUID) -> Binding<Bool> {
        Binding(
            get: { story.linkedProjectIds.contains(projectId) },
            set: { isLinked in
                story.linkedProjectIds.removeAll { $0 == projectId }
                if isLinked { story.linkedProjectIds.append(projectId) }
            }
        )
    }

    var storyBinding: Binding<UUID?> {
        Binding(get: { task.storyId }, set: { task.storyId = $0 })
    }

    /// A field shared by stories and tasks, bound to whichever the form edits.
    func field<Value>(
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

    var permissionBinding: Binding<PermissionMode?> {
        Binding(get: { task.agent.permissionMode }, set: { task.agent.permissionMode = $0 })
    }
}
