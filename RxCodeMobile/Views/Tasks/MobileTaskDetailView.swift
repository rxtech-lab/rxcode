import RxCodeCore
import RxCodeSync
import SwiftUI

/// A single task, in two tabs like the Mac task form: Runs (each prompt the
/// agent was sent and its answer, with follow-ups) and Config (description,
/// classification, agent, and the actions the desktop offers).
struct MobileTaskDetailView: View {
    enum Tab: Hashable {
        case runs
        case config
    }

    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let taskID: UUID
    let onOpenChat: (String) -> Void

    @State private var editingTask: ProjectTask?
    @State private var followUpTask: ProjectTask?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false
    /// `nil` until the user picks one: Runs for a task that has a thread,
    /// Config otherwise.
    @State private var selectedTab: Tab?

    private var board: TaskBoard { state.taskBoard(for: projectID) }
    private var task: ProjectTask? { board.tasks.first { $0.id == taskID } }

    private func tab(for task: ProjectTask) -> Tab {
        selectedTab ?? (state.taskSessionID(task) != nil ? .runs : .config)
    }

    var body: some View {
        Group {
            if let task {
                switch tab(for: task) {
                case .runs:
                    MobileTaskRunsView(
                        task: task,
                        onFollowUp: { followUpTask = task },
                        onOpenChat: onOpenChat
                    )
                case .config:
                    content(task)
                }
            } else {
                ContentUnavailableView("Task Not Found", systemImage: "checklist", description: Text("It may have been deleted on your Mac."))
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: Binding(
                        get: { tab(for: task) },
                        set: { selectedTab = $0 }
                    )) {
                        Text("Runs").tag(Tab.runs)
                        Text("Config").tag(Tab.config)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("task-detail-tab")
                }
            }
        }
        .sheet(item: $editingTask) { task in
            NavigationStack {
                MobileTaskFormView(task: task, isNew: false)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .sheet(item: $followUpTask) { task in
            NavigationStack {
                MobileTaskFollowUpView(task: task)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.medium, .large])
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    private func content(_ task: ProjectTask) -> some View {
        let column = board.column(for: task.status)
        let isLocked = board.isStatusLocked(task)
        let sessionID = state.taskSessionID(task)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(task.title.isEmpty ? String(localized: "Untitled Task") : task.title)
                        .font(.title3.weight(.semibold))
                    MobileTaskPills(
                        board: board,
                        column: column,
                        story: board.story(id: task.storyId),
                        priority: task.priority,
                        version: task.version,
                        milestone: task.milestone,
                        tags: task.tags
                    )
                    if state.isTaskAgentRunning(task) {
                        Label("Agent is working on this task", systemImage: "bolt.fill")
                            .font(.footnote)
                            .foregroundStyle(.blue)
                    } else if state.isTaskClassifying(task) {
                        Label("Filling in details…", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.purple)
                    }
                }
                .padding(.vertical, 4)
            }

            if let reason = task.attentionReason {
                Section("Needs Attention") {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            Section("Description") {
                if task.details.isEmpty {
                    Text("No description")
                        .foregroundStyle(.secondary)
                } else {
                    Text(markdown(task.details))
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                if task.isDescriptionLocked {
                    Label("Locked once the task has run, so it keeps matching what the agent was asked to do.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let parentID = task.parentTaskId,
               let parent = board.tasks.first(where: { $0.id == parentID }) {
                Section("Starts After") {
                    Button(parent.title) { editingTask = parent }
                }
            }

            let linkedChildren = board.tasks.filter { $0.parentTaskId == task.id }
            if !linkedChildren.isEmpty {
                Section("Linked Tasks") {
                    ForEach(linkedChildren) { child in
                        Button(child.title) { editingTask = child }
                    }
                }
            }

            Section("Agent") {
                LabeledContent("Model", value: state.taskAgentLabel(task.agent))
                if task.agent.planMode {
                    LabeledContent("Plan mode", value: String(localized: "On"))
                }
                if let type = board.itemType(id: task.typeId) {
                    LabeledContent("Type", value: type.name)
                }
            }

            Section {
                if let sessionID {
                    Button {
                        onOpenChat(sessionID)
                    } label: {
                        Label("Open Chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
                if task.agent.isAssigned, !column.triggersChat, board.firstChatColumn != nil {
                    Button {
                        perform { try await state.runTask(task) }
                    } label: {
                        Label("Run with Agent", systemImage: "play.fill")
                    }
                }
                if sessionID != nil, !isLocked {
                    Button {
                        followUpTask = task
                    } label: {
                        Label("Send Follow-up", systemImage: "arrowshape.turn.up.right")
                    }
                }
                if let prompt = task.checkErrorFixPrompt, !isLocked,
                   sessionID != nil || (task.agent.isAssigned && board.firstChatColumn != nil) {
                    Button {
                        perform {
                            if sessionID != nil {
                                try await state.sendTaskFollowUp(task, text: prompt)
                            } else {
                                try await state.runTask(task)
                            }
                        }
                    } label: {
                        Label("Fix Check Error", systemImage: "wrench.and.screwdriver")
                    }
                }
                Menu {
                    ForEach(board.effectiveColumns) { target in
                        Button {
                            perform { try await state.moveTask(task, to: target.id) }
                        } label: {
                            Label(target.name, systemImage: target.systemImage)
                        }
                        .disabled(target.id == column.id)
                    }
                } label: {
                    Label("Move To", systemImage: "arrow.right.square")
                }
                .disabled(isLocked)
            } footer: {
                if isLocked {
                    Text("The agent is working on this task; it moves on when the turn finishes.")
                }
            }
            .disabled(isWorking)

            Section {
                LabeledContent("Created", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button("Delete Task", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editingTask = task }
            }
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Delete Task?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                perform {
                    try await state.deleteTask(task)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A story: its description, progress, and child tasks.
struct MobileStoryDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let storyID: UUID
    let onOpenChat: (String) -> Void

    @State private var editingStory: ProjectStory?
    @State private var editingTask: ProjectTask?
    @State private var showingQuickAdd = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?

    private var board: TaskBoard { state.taskBoard(for: projectID) }
    private var story: ProjectStory? { board.story(id: storyID) }

    var body: some View {
        Group {
            if let story {
                content(story)
            } else {
                ContentUnavailableView("Story Not Found", systemImage: "rectangle.stack", description: Text("It may have been deleted on your Mac."))
            }
        }
        .navigationTitle("Story")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingStory) { story in
            NavigationStack {
                MobileStoryFormView(story: story, isNew: false)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .sheet(item: $editingTask) { task in
            NavigationStack {
                MobileTaskFormView(task: task, isNew: !board.tasks.contains { $0.id == task.id })
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.large])
        }
        .sheet(isPresented: $showingQuickAdd) {
            NavigationStack {
                MobileQuickAddTaskView(projectID: projectID, storyID: storyID)
                    .environmentObject(state)
            }
            .mobileSheetPresentation([.medium, .large])
        }
        .mobileTaskErrorAlert($errorMessage)
    }

    private func content(_ story: ProjectStory) -> some View {
        let tasks = board.tasks(inStory: story.id).sorted {
            let lhs = board.columnIndex(of: board.resolvedStatus(of: $0))
            let rhs = board.columnIndex(of: board.resolvedStatus(of: $1))
            return lhs == rhs ? $0.sortIndex < $1.sortIndex : lhs < rhs
        }
        let progress = board.progress(for: story)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(story.title.isEmpty ? String(localized: "Untitled Story") : story.title)
                        .font(.title3.weight(.semibold))
                    if progress.total > 0 {
                        MobileStoryProgressBar(progress: progress)
                    }
                    MobileTaskPills(
                        board: board,
                        column: progress.total > 0 ? board.column(for: board.rolledUpStatus(for: story)) : nil,
                        priority: story.priority,
                        version: story.version,
                        milestone: story.milestone,
                        tags: story.tags
                    )
                }
                .padding(.vertical, 4)
                if !story.details.isEmpty {
                    Text(story.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                if tasks.isEmpty {
                    Text("No tasks in this story yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    NavigationLink(value: MobileTaskRoute.task(projectID: projectID, taskID: task.id)) {
                        MobileTaskRow(task: task, board: board, showsColumn: true, showsStory: false)
                    }
                    .modifier(MobileTaskActions(
                        task: task,
                        board: board,
                        onEdit: { editingTask = task },
                        onOpenChat: onOpenChat,
                        onError: { errorMessage = $0 }
                    ))
                }
            } header: {
                Text("Tasks")
            }

            Section {
                Button("Delete Story", role: .destructive) {
                    showingDeleteConfirm = true
                }
            } footer: {
                Text("Tasks in this story are kept and moved to the board root.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingTask = state.newTaskDraft(projectID: projectID, story: story)
                    } label: {
                        Label("New Task", systemImage: "square.and.pencil")
                    }
                    Button {
                        showingQuickAdd = true
                    } label: {
                        Label("Quick Add Task", systemImage: "sparkles")
                    }
                    Divider()
                    Button {
                        editingStory = story
                    } label: {
                        Label("Edit Story", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete Story?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Story", role: .destructive) {
                Task {
                    do {
                        try await state.deleteStory(story)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
