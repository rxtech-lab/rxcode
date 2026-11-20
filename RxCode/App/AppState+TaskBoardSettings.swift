import Foundation
import RxCodeCore

extension AppState {
    // MARK: - Saved views

    func upsertSavedView(_ view: TaskSavedView, projectId: UUID) {
        updateBoard(projectId) { board in
            board.upsertSavedView(view)
        }
    }

    /// Makes `viewId` the view the project page opens on and the dashboard
    /// card previews.
    func setDefaultSavedView(_ viewId: UUID, projectId: UUID) {
        updateBoard(projectId) { board in
            board.setDefaultView(viewId)
        }
    }

    /// Tab drag-and-drop: `view` takes `target`'s slot. Persists the implicit
    /// default tab too, since the order now lives in `savedViews`.
    func reorderSavedView(_ view: UUID, onto target: UUID, projectId: UUID) {
        updateBoard(projectId) { board in
            guard let order = board.viewOrder(moving: view, to: target) else { return }
            board.savedViews = order
        }
    }

    func deleteSavedView(_ view: TaskSavedView, projectId: UUID) {
        updateBoard(projectId) { board in
            board.savedViews.removeAll { $0.id == view.id }
        }
    }

    // MARK: - Labels and types

    /// Sets a tag's color, creating the label entry if the tag had none.
    func setLabelColor(_ tag: String, colorHex: String, projectId: UUID) {
        updateBoard(projectId) { board in
            if let idx = board.labels.firstIndex(where: { $0.name == tag }) {
                board.labels[idx].colorHex = colorHex
            } else {
                board.labels.append(TaskLabel(name: tag, colorHex: colorHex))
            }
        }
    }

    /// Adds a label so it can be picked before any item uses it.
    func addLabel(_ name: String, colorHex: String, projectId: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !taskBoard(for: projectId).allTags.contains(trimmed) else { return }
        setLabelColor(trimmed, colorHex: colorHex, projectId: projectId)
    }

    /// Renames a tag everywhere it is used, and on its label and saved views,
    /// so the rename behaves like editing a GitHub label.
    func renameLabel(_ tag: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag else { return }
        updateBoard(projectId) { board in
            func rename(_ tags: [String]) -> [String] {
                var result: [String] = []
                for existing in tags {
                    let renamed = existing == tag ? trimmed : existing
                    if !result.contains(renamed) { result.append(renamed) }
                }
                return result
            }
            for idx in board.tasks.indices { board.tasks[idx].tags = rename(board.tasks[idx].tags) }
            for idx in board.stories.indices { board.stories[idx].tags = rename(board.stories[idx].tags) }
            for idx in board.savedViews.indices { board.savedViews[idx].tags = rename(board.savedViews[idx].tags) }
            // Merging into an existing label keeps the target's color.
            if board.labels.contains(where: { $0.name == trimmed }) {
                board.labels.removeAll { $0.name == tag }
            } else if let idx = board.labels.firstIndex(where: { $0.name == tag }) {
                board.labels[idx].name = trimmed
            }
        }
    }

    /// Deletes a tag from every story, task and saved view, along with its color.
    func deleteLabel(_ tag: String, projectId: UUID) {
        updateBoard(projectId) { board in
            for idx in board.tasks.indices { board.tasks[idx].tags.removeAll { $0 == tag } }
            for idx in board.stories.indices { board.stories[idx].tags.removeAll { $0 == tag } }
            for idx in board.savedViews.indices { board.savedViews[idx].tags.removeAll { $0 == tag } }
            board.labels.removeAll { $0.name == tag }
        }
    }

    /// Renames a version on every story, task and saved view using it.
    /// Renaming onto an existing version merges the two.
    func renameVersion(_ version: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != version else { return }
        updateBoard(projectId) { board in
            TaskMetadataEdit(field: .versions, original: version, name: trimmed).apply(to: &board)
        }
    }

    /// Clears a version from every story, task and saved view using it.
    func deleteVersion(_ version: String, projectId: UUID) {
        updateBoard(projectId) { board in
            board.versions.removeAll { $0 == version }
            for idx in board.tasks.indices where board.tasks[idx].version == version {
                board.tasks[idx].version = nil
            }
            for idx in board.stories.indices where board.stories[idx].version == version {
                board.stories[idx].version = nil
            }
            for idx in board.savedViews.indices {
                board.savedViews[idx].versions.removeAll { $0 == version }
            }
        }
    }

    /// Renames a milestone on every story and task using it. Renaming onto an
    /// existing milestone merges the two.
    func renameMilestone(_ milestone: String, to newName: String, projectId: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != milestone else { return }
        updateBoard(projectId) { board in
            TaskMetadataEdit(field: .milestones, original: milestone, name: trimmed).apply(to: &board)
        }
    }

    /// Clears a milestone from every story and task using it.
    func deleteMilestone(_ milestone: String, projectId: UUID) {
        updateBoard(projectId) { board in
            board.milestones.removeAll { $0 == milestone }
            for idx in board.tasks.indices where board.tasks[idx].milestone == milestone {
                board.tasks[idx].milestone = nil
            }
            for idx in board.stories.indices where board.stories[idx].milestone == milestone {
                board.stories[idx].milestone = nil
            }
            for idx in board.savedViews.indices {
                board.savedViews[idx].milestones.removeAll { $0 == milestone }
            }
        }
    }

    /// Inserts or replaces an item type. The first edit persists the default
    /// types, so editing one doesn't make the others disappear.
    func upsertItemType(_ type: TaskItemType, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.itemTypes.isEmpty {
                board.itemTypes = TaskItemType.defaults
            }
            if let idx = board.itemTypes.firstIndex(where: { $0.id == type.id }) {
                board.itemTypes[idx] = type
            } else {
                board.itemTypes.append(type)
            }
        }
    }

    /// Deletes an item type and clears it from every story and task using it.
    func deleteItemType(_ type: TaskItemType, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.itemTypes.isEmpty {
                board.itemTypes = TaskItemType.defaults
            }
            board.itemTypes.removeAll { $0.id == type.id }
            for idx in board.tasks.indices where board.tasks[idx].typeId == type.id {
                board.tasks[idx].typeId = nil
            }
            for idx in board.stories.indices where board.stories[idx].typeId == type.id {
                board.stories[idx].typeId = nil
            }
        }
    }

    // MARK: - Columns

    /// Inserts or replaces a column. The first edit persists the default
    /// columns so the board stops following `TaskColumn.defaults`.
    func upsertColumn(_ column: TaskColumn, projectId: UUID) {
        updateBoard(projectId) { board in
            if board.columns.isEmpty { board.columns = TaskColumn.defaults }
            if let idx = board.columns.firstIndex(where: { $0.id == column.id }) {
                board.columns[idx] = column
            } else {
                board.columns.append(column)
            }
        }
    }

    /// Replaces the column order with `order` (ids of the existing columns).
    func reorderColumns(_ order: [TaskStatus], projectId: UUID) {
        updateBoard(projectId) { board in
            let current = board.effectiveColumns
            let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            var reordered = order.compactMap { byId[$0] }
            reordered += current.filter { !order.contains($0.id) }
            board.columns = reordered
        }
    }

    /// Deletes a column, moving its tasks to `destination` (default: the first
    /// remaining column). Triggers that routed cards into it route them to
    /// `destination` instead, so the board's flow survives; saved-view filters
    /// drop it. The last column can't be deleted.
    func deleteColumn(_ column: TaskColumn, projectId: UUID, moveTasksTo destination: TaskStatus? = nil) {
        updateBoard(projectId) { board in
            var remaining = board.effectiveColumns.filter { $0.id != column.id }
            guard !remaining.isEmpty else { return }
            let target = destination.flatMap { id in remaining.first { $0.id == id }?.id } ?? remaining[0].id

            for idx in remaining.indices {
                for event in TaskTriggerEvent.allCases where remaining[idx].target(for: event) == column.id {
                    remaining[idx].setTarget(remaining[idx].id == target ? nil : target, for: event)
                }
            }
            board.columns = remaining

            for idx in board.tasks.indices where board.tasks[idx].status == column.id {
                board.tasks[idx].status = target
                board.tasks[idx].sortIndex = board.appendSortIndex(for: target)
                board.tasks[idx].updatedAt = Date()
            }
            for idx in board.savedViews.indices {
                board.savedViews[idx].statuses.removeAll { $0 == column.id }
                board.savedViews[idx].storyPanelStatuses.removeAll { $0 == column.id }
            }
        }
    }
}
