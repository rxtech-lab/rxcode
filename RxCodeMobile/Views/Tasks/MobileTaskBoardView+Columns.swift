import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI

extension MobileTaskBoardView {
    // MARK: - Kanban

    /// Scrolls horizontally only; each column fits the visible height and
    /// scrolls its own cards, so the last card is never cut off.
    var kanbanBoard: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                // Keep column destinations alive for moves across the board.
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visibleColumns) { column in
                        kanbanColumn(column, height: max(proxy.size.height, 0))
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: taskCardLayout)
        .clipped()
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("tasks-ipad-kanban")
    }

    private func kanbanColumn(_ column: TaskColumn, height: CGFloat) -> some View {
        let tasks = columnTasks(column)
        return TaskKanbanColumnContent(
            headerSpacing: 0,
            cardInsets: EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)
        ) {
            HStack(spacing: 6) {
                Image(systemName: column.systemImage)
                    .foregroundStyle(column.tint)
                Text(column.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(tasks.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                columnOptions(column)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task-column-\(column.id.rawValue)")

        } cards: {
            if tasks.isEmpty {
                ContentUnavailableView("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change this column’s filters or add a task."))
                    .frame(maxWidth: .infinity, minHeight: max(0, height - 80))
            }
            ForEach(tasks) { task in
                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                    MobileTaskRow(task: task, board: board)
                        .mobileCardMenuInset()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .matchedGeometryEffect(
                    id: task.id,
                    in: taskCardNamespace,
                    properties: reduceMotion ? [] : .frame
                )
                .transition(.identity)
                .modifier(MobileTaskActions(
                    task: task,
                    board: board,
                    onEdit: { editingTask = task },
                    onOpenChat: openChat,
                    onError: { errorMessage = $0 }
                ))
                .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task) && state.canEditCard(task)))
                .mobileLegacyDrop { items, _ in
                    drop(items, before: task, in: column.id)
                }
                .mobileReorderItem()
                .moveDisabled(board.isStatusLocked(task) || currentView.sort(for: column.id).field != .manual)
            }
            .mobileReorderable()
        }
        .frame(width: 300, height: height, alignment: .top)
        // Keep scrolling cards inside the column's rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(column.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(column.tint.opacity(0.18)))
        .contentShape(Rectangle())
        .mobileTaskReorderContainer(status: column.id, move: reorderTasks)
        // Dropping anywhere else in the column appends to its end.
        .mobileLegacyDrop { items, _ in
            drop(items, before: nil, in: column.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-kanban-column-\(column.id.rawValue)")
    }

    // MARK: - Tasks

    var tableSection: some View {
        Section {
            ForEach(visibleTasks.sorted { lhs, rhs in
                let left = board.columnIndex(of: board.resolvedStatus(of: lhs))
                let right = board.columnIndex(of: board.resolvedStatus(of: rhs))
                return left == right ? lhs.sortIndex < rhs.sortIndex : left < right
            }) { task in
                MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                    MobileTaskRow(task: task, board: board)
                        .mobileCardMenuInset()
                }
                .modifier(MobileTaskActions(
                    task: task,
                    board: board,
                    onEdit: { editingTask = task },
                    onOpenChat: openChat,
                    onError: { errorMessage = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    var taskSections: some View {
        ForEach(visibleColumns) { column in
            let tasks = columnTasks(column)
            if !tasks.isEmpty || searchText.isEmpty || !localFilter(column).isEmpty {
                Section {
                    if !collapsedColumns.contains(column.id) {
                        ForEach(tasks) { task in
                            MobileTaskDetailButton(route: MobileTaskRoute.task(projectID: projectID, taskID: task.id), onOpenChat: openChat) {
                                MobileTaskRow(task: task, board: board)
                                    .mobileCardMenuInset()
                            }
                            .modifier(MobileTaskActions(
                                task: task,
                                board: board,
                                onEdit: { editingTask = task },
                                onOpenChat: openChat,
                                onError: { errorMessage = $0 }
                            ))
                            .modifier(MobileTaskDraggable(task: task, isEnabled: !board.isStatusLocked(task) && state.canEditCard(task)))
                            .mobileLegacyDrop { items, _ in
                                drop(items, before: task, in: column.id)
                            }
                            .mobileReorderItem()
                            .moveDisabled(board.isStatusLocked(task) || currentView.sort(for: column.id).field != .manual)
                        }
                        .mobileReorderable(collectionID: column.id)
                    }
                } header: {
                    columnHeader(column, count: tasks.count)
                        .mobileLegacyDrop { items, _ in
                            drop(items, before: nil, in: column.id)
                        }
                }
            }
        }
    }

    private func columnHeader(_ column: TaskColumn, count: Int) -> some View {
        HStack {
            Button {
                withAnimation {
                    if collapsedColumns.contains(column.id) {
                        collapsedColumns.remove(column.id)
                    } else {
                        collapsedColumns.insert(column.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: column.systemImage)
                        .foregroundStyle(column.tint)
                    Text(column.name)
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(collapsedColumns.contains(column.id) ? 0 : 90))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task-column-\(column.id.rawValue)")
        columnOptions(column)
        }
    }

    // MARK: - Stories

    @ViewBuilder
    var storySection: some View {
        let rollups = board.storyRollups()
        let stories = visibleStories.sorted { $0.updatedAt > $1.updatedAt }
        Section {
            ForEach(stories) { story in
                MobileTaskDetailButton(route: MobileTaskRoute.story(projectID: projectID, storyID: story.id), onOpenChat: openChat) {
                    MobileStoryRow(story: story, board: board, rollup: rollups[story.id])
                        .mobileCardMenuInset()
                }
                .overlay(alignment: .topTrailing) {
                    if state.canEditCard(story) {
                        MobileCardMenu(label: "Story Actions", identifier: "story-actions-\(story.id)") {
                            Button {
                                editingStory = story
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                perform { try await state.deleteStory(story) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
}
