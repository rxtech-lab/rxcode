import RxCodeCore
import SwiftUI

/// The task lists of `TaskFormSheet`: a story's tasks and the tasks linked to start after a task.
extension TaskFormSheet {
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
        Section {
            ForEach(linkedChildren) { child in
                let childBoard = appState.taskBoard(for: child.projectId)
                Button {
                    childTask = .task(child)
                } label: {
                    HStack(spacing: 8) {
                        TaskStatusIcon(status: child.status, board: childBoard, size: 12)
                        Text(child.title.isEmpty ? String(localized: "Untitled task") : child.title)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        // A linked task may live on another project's board.
                        if child.projectId != task.projectId,
                           let project = appState.projects.first(where: { $0.id == child.projectId }) {
                            Text(project.name)
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Text(childBoard.column(for: child.status).name)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(child.title)
                .accessibilityIdentifier("task-form-linked-task-\(child.id)")
            }
        } header: {
            HStack {
                Text("Linked Tasks")
                Spacer()
                Text("\(linkedChildren.count)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        } footer: {
            Text("These tasks start after this one reaches Pending Review or Done.")
        }
    }

    /// Tasks in any project that start after this one.
    var linkedChildren: [ProjectTask] {
        appState.allTasks().filter { $0.parentTaskIds.contains(task.id) }
    }
}
