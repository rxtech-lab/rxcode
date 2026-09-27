import RxCodeCore
import SwiftUI

/// The sidebar's "Scheduled" route: every cron-scheduled task, grouped by
/// project, with its schedule, next run, and an enable switch.
struct ScheduledTasksView: View {
    @Environment(AppState.self) private var appState

    /// The sheet's subject: a new draft or an existing task being edited.
    @State private var editing: EditingTask?
    @State private var taskToDelete: ScheduledTask?

    private struct EditingTask: Identifiable {
        let task: ScheduledTask
        /// How a new task is written; `nil` when editing an existing one.
        var mode: TaskCreationMode?
        var id: UUID { task.id }
    }

    private struct ProjectGroup: Identifiable {
        let project: Project
        let tasks: [ScheduledTask]
        var id: UUID { project.id }
    }

    /// Projects in sidebar order, each with its scheduled tasks by name.
    private var groups: [ProjectGroup] {
        let byProject = Dictionary(grouping: appState.scheduledTasks, by: \.projectId)
        return appState.projects.compactMap { project in
            guard let tasks = byProject[project.id], !tasks.isEmpty else { return nil }
            let sorted = tasks.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return ProjectGroup(project: project, tasks: sorted)
        }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(ClaudeTheme.background)
        .onAppear {
            AnalyticsService.shared.log(.scheduledTasksOpened)
        }
        .sheet(item: $editing) { editing in
            ScheduledTaskFormSheet(
                task: editing.task,
                isNew: !appState.scheduledTasks.contains { $0.id == editing.task.id },
                mode: editing.mode
            )
            .environment(appState)
        }
        .confirmationDialog(
            "Delete this scheduled task?",
            isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: taskToDelete
        ) { task in
            Button("Delete", role: .destructive) {
                appState.deleteScheduledTask(id: task.id)
            }
        } message: { task in
            Text("\"\(task.name)\" will stop running. This can't be undone.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                // Refreshes the relative "next run" labels while the page is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups) { group in
                            projectSection(group, now: context.date)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ClaudeTheme.accent.opacity(0.14))
                Image(systemName: GeneralRoute.scheduled.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled Tasks")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text(heroSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Spacer(minLength: 0)

            newTaskButton
        }
    }

    private var heroSubtitle: String {
        let tasks = groups.flatMap(\.tasks)
        let active = tasks.filter(\.isEnabled).count
        return String(localized: "\(active) of \(tasks.count) scheduled tasks active.")
    }

    private var newTaskButton: some View {
        Menu {
            newTaskMenuItems()
        } label: {
            Label("New Scheduled Task", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(appState.projects.isEmpty)
        .help(appState.projects.isEmpty ? "Add a project first" : "Schedule a prompt to run periodically, written with AI or in a form")
        .accessibilityIdentifier("scheduled-task-add")
    }

    @ViewBuilder
    private func newTaskMenuItems(projectId: UUID? = nil) -> some View {
        Button {
            startNewTask(projectId: projectId, mode: .ai)
        } label: {
            Label("Create Scheduled Task with AI", systemImage: TaskCreationMode.ai.systemImage)
        }
        Button {
            startNewTask(projectId: projectId, mode: .form)
        } label: {
            Label("Create Scheduled Task with Form", systemImage: TaskCreationMode.form.systemImage)
        }
    }

    private func startNewTask(projectId: UUID? = nil, mode: TaskCreationMode) {
        guard let projectId = projectId ?? appState.projects.first?.id else { return }
        editing = EditingTask(
            task: ScheduledTask(
                projectId: projectId,
                name: "",
                prompt: "",
                cronExpression: "0 9 * * *"
            ),
            mode: mode
        )
    }

    // MARK: - Sections

    private func projectSection(_ group: ProjectGroup, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(group.project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Menu {
                    newTaskMenuItems(projectId: group.project.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Schedule a task in \(group.project.name)")
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 {
                        Divider().overlay(ClaudeTheme.borderSubtle)
                    }
                    ScheduledTaskRow(
                        task: task,
                        now: now,
                        onEdit: { editing = EditingTask(task: task) },
                        onDelete: { taskToDelete = task }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .fill(ClaudeTheme.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                    .strokeBorder(ClaudeTheme.borderSubtle)
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.surfaceSecondary)
                    .frame(width: 56, height: 56)
                Image(systemName: GeneralRoute.scheduled.systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Text("No Scheduled Tasks")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text("Schedule a prompt to run in a project on a cron expression, like every weekday at 9:00.")
                .font(.system(size: 13))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            newTaskButton
                .padding(.top, 4)
        }
        .padding(.vertical, 60)
    }
}

// MARK: - Row

private struct ScheduledTaskRow: View {
    @Environment(AppState.self) private var appState
    let task: ScheduledTask
    let now: Date
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name.isEmpty ? String(localized: "Untitled") : task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(task.isEnabled ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                    .lineLimit(1)
                if !task.prompt.isEmpty {
                    Text(task.prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text(task.cronExpression)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 4))
                    nextRunLabel
                    Label(appState.taskAgentLabel(appState.resolvedAgent(for: task)), systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .help(task.agent.isAssigned ? "Model" : "Default task agent")
                    if let lastRunAt = task.lastRunAt {
                        Text("Last run \(lastRunAt, format: .relative(presentation: .named))")
                            .font(.system(size: 11))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            if isHovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit scheduled task")
            }

            Toggle("Enabled", isOn: Binding(
                get: { task.isEnabled },
                set: { appState.setScheduledTaskEnabled(id: task.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(task.isEnabled ? "Pause this schedule" : "Resume this schedule")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? ClaudeTheme.sidebarItemHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", systemImage: "pencil", action: onEdit)
            Button(task.isEnabled ? "Pause" : "Resume", systemImage: task.isEnabled ? "pause" : "play") {
                appState.setScheduledTaskEnabled(id: task.id, !task.isEnabled)
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier("scheduled-task-\(task.id.uuidString)")
    }

    @ViewBuilder
    private var nextRunLabel: some View {
        if task.schedule == nil {
            Label("Invalid schedule", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.statusError)
        } else if !task.isEnabled {
            Label("Paused", systemImage: "pause.circle")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
        } else if let next = task.nextRunDate(after: now) {
            Label {
                Text("Next \(next, format: .relative(presentation: .named))")
            } icon: {
                Image(systemName: "clock")
            }
            .font(.system(size: 11))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .help(next.formatted(date: .complete, time: .shortened))
        } else {
            Text("Never runs")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.statusWarning)
        }
    }
}
