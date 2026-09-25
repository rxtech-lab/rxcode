import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit sheet for a task or a story.
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

    @State private var isStory = false
    @State private var task = ProjectTask(projectId: UUID(), title: "")
    @State private var story = ProjectStory(projectId: UUID(), title: "")
    @State private var tagInput = ""
    @State private var showingImagePicker = false
    @State private var isExistingRecord = false
    @State private var tab: Tab = .details
    /// A task opened from a story's Tasks section, edited in a nested form.
    @State private var childTask: TaskBoardSheet?

    private enum Tab: Hashable {
        case details, run
    }

    /// A task that has left Pending has a run to look at. Uses the stored
    /// status, so flipping the picker in this form doesn't swap tabs mid-edit.
    private var showsRunTab: Bool {
        guard isExistingRecord, !isStory, let stored = appState.task(id: task.id) else { return false }
        return stored.status != .pending
    }

    /// Uses the stored task, not the draft, so changing the status picker in
    /// this form doesn't lock the field mid-edit.
    private var isDescriptionLocked: Bool {
        guard !isStory else { return false }
        return appState.task(id: task.id)?.isDescriptionLocked ?? false
    }

    private var isStatusLocked: Bool {
        appState.task(id: task.id)?.isStatusLocked ?? false
    }

    private var canSave: Bool {
        let title = isStory ? story.title : task.title
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsRunTab {
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

            if showsRunTab, tab == .run {
                TaskRunView(taskId: task.id)
                    .frame(maxHeight: .infinity)
            } else {
                detailsForm
            }

            footer
        }
        .frame(width: 560, height: 680)
        .sheet(item: $childTask) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: story.projectId)
                .environment(appState)
                .environment(windowState)
        }
        .onAppear {
            loadDraft()
            // Open on the outcome: a task that has run is usually reopened to
            // see what the agent did.
            if showsRunTab { tab = .run }
        }
    }

    private var detailsForm: some View {
        Form {
            // Kind is fixed once a record exists — converting a story into a
            // task (or back) would orphan children or lose the agent assignment.
            if !isExistingRecord {
                Section {
                    Picker("Kind", selection: $isStory) {
                        Text("Task").tag(false)
                        Text("Story").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            detailsSection
            if isStory {
                storyTasksSection
            }
            if !isStory {
                classificationSection
                tagsSection
                agentSection
                attachmentsSection
            }
        }
        .formStyle(.grouped)
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
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleImageImport(result)
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
                    if isStory {
                        appState.deleteStory(story)
                    } else {
                        appState.deleteTask(task)
                    }
                    dismiss()
                }
            }
            if isExistingRecord, !isStory, appState.canOpenChat(for: task) {
                Button("Open Chat") {
                    dismiss()
                    appState.openChat(for: task, in: windowState)
                }
                .help("Open the thread this task ran in")
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

            TextField(
                "Description",
                text: isStory ? $story.details : $task.details,
                prompt: Text("Add more detail for the agent"),
                axis: .vertical
            )
            .lineLimit(4...8)
            .multilineTextAlignment(.leading)
            .disabled(isDescriptionLocked)

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

    /// A story's tasks. Each row, and New Task, opens the full task form.
    private var storyTasksSection: some View {
        Section {
            let existing = isExistingRecord
                ? appState.taskBoard(for: story.projectId).tasks(inStory: story.id).sorted { $0.sortIndex < $1.sortIndex }
                : []
            ForEach(existing) { task in
                Button {
                    childTask = .task(task)
                } label: {
                    HStack(spacing: 8) {
                        TaskStatusIcon(status: task.status, size: 12)
                        Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(task.status.displayName)
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

    private var classificationSection: some View {
        Section("Classification") {
            Picker("Status", selection: $task.status) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            // Only the stored status locks the picker, so a new task can still
            // be created straight into In Progress.
            .disabled(isStatusLocked)
            .help(isStatusLocked ? "The agent is working on this task; it moves to Pending Review when the turn finishes." : "")

            Picker("Story", selection: storyBinding) {
                Text("None").tag(UUID?.none)
                ForEach(appState.stories(projectFilter: task.projectId)) { story in
                    Text(story.title).tag(UUID?.some(story.id))
                }
            }

            TextField("Version", text: versionBinding, prompt: Text("e.g. v1.3.0"))
                .multilineTextAlignment(.leading)
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            HStack(spacing: 6) {
                TextField("Add a tag", text: $tagInput, prompt: Text("Add a tag"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !task.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(task.tags, id: \.self) { tag in
                        Button {
                            task.tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 3) {
                                Text(tag)
                                Image(systemName: "xmark")
                                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
                            }
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(ClaudeTheme.surfaceSecondary))
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag")
                    }
                }
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
        Section("Images") {
            if !task.attachments.isEmpty {
                ForEach(task.attachments, id: \.id) { dto in
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
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
                        .help("Remove image")
                    }
                }
            }

            Button {
                showingImagePicker = true
            } label: {
                Label("Add Images…", systemImage: "photo.badge.plus")
            }
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

    private var versionBinding: Binding<String> {
        Binding(
            get: { task.version ?? "" },
            set: { task.version = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    private var permissionBinding: Binding<PermissionMode?> {
        Binding(get: { task.agent.permissionMode }, set: { task.agent.permissionMode = $0 })
    }

    // MARK: - Actions

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
        childTask = .task(ProjectTask(projectId: story.projectId, storyId: story.id, title: ""))
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !task.tags.contains(trimmed) else {
            tagInput = ""
            return
        }
        task.tags.append(trimmed)
        tagInput = ""
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard let attachment = AttachmentFactory.fromFileURL(url) else { continue }
            let dto = attachment.persistableInTaskBoard().dto
            guard !task.attachments.contains(where: { $0.path == dto.path }) else { continue }
            task.attachments.append(dto)
        }
    }

    private func save() {
        if isStory {
            story.title = story.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertStory(story)
        } else {
            task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.upsertTask(task)
        }
        dismiss()
    }
}
