import RxCodeCore
import SwiftUI

// MARK: - ProjectChatsList

struct ProjectChatsList: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private static let defaultVisibleThreadCount = 5

    let project: Project
    let onSelectSession: (String) -> Void
    let onRenameSession: (ChatSession) -> Void
    let onArchiveSession: (ChatSession) -> Void
    let onDeleteSession: (ChatSession) -> Void

    @State private var additionalVisibleThreadCount = 0
    @State private var performance = ChatHistoryPerformanceLog()
    @State private var taskSheet: TaskBoardSheet?
    @State private var creatingTaskSessionIds: Set<String> = []
    @State private var showTaskCreationError = false
    /// Parent thread ids whose nested review children are currently expanded.
    @State private var expandedReviewParentIds: Set<String> = []

    private struct HistorySnapshot {
        let projectThreadCount: Int
        let sessions: [ChatSession.Summary]
        let childrenByParent: [String: [ChatSession.Summary]]
        let collapsedVisibleCount: Int
    }

    /// Build once per body evaluation. Row closures capture this immutable
    /// snapshot instead of filtering and grouping the full history per row.
    private func historySnapshot() -> HistorySnapshot {
        let filterStart = DispatchTime.now().uptimeNanoseconds
        let allSessions = HistoryListView.filteredSummaries(
            from: appState.allSessionSummaries,
            projectId: project.id,
            showArchived: false
        )
        performance.record("filter-sort", since: filterStart, project: project.id)

        let groupingStart = DispatchTime.now().uptimeNanoseconds
        let ids = Set(allSessions.map(\.id))
        var sessions: [ChatSession.Summary] = []
        var childrenByParent: [String: [ChatSession.Summary]] = [:]
        for summary in allSessions {
            if let parent = summary.parentThreadId, ids.contains(parent) {
                childrenByParent[parent, default: []].append(summary)
            } else {
                // Keep orphaned children visible when their parent is archived
                // or belongs to another project.
                sessions.append(summary)
            }
        }
        childrenByParent = childrenByParent.mapValues { $0.sorted { $0.updatedAt < $1.updatedAt } }
        performance.record("child-grouping", since: groupingStart, project: project.id)

        let pinnedCount = sessions.prefix(while: { $0.isPinned }).count
        let pinnedShown = min(pinnedCount, 6)
        let unpinnedShown = max(4, 6 - pinnedShown)
        return HistorySnapshot(
            projectThreadCount: allSessions.count,
            sessions: sessions,
            childrenByParent: childrenByParent,
            collapsedVisibleCount: max(Self.defaultVisibleThreadCount, pinnedShown + unpinnedShown)
        )
    }

    var body: some View {
        let _ = performance.record("list-body", project: project.id)
        let snapshot = historySnapshot()
        let visibleCount = min(snapshot.sessions.count, snapshot.collapsedVisibleCount + additionalVisibleThreadCount)
        let visibleSessions = Array(snapshot.sessions.prefix(visibleCount))
        let hiddenThreadCount = snapshot.sessions.count - visibleCount
        LazyVStack(alignment: .leading, spacing: 0) {
            if snapshot.sessions.isEmpty {
                Text("No chats yet")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.leading, 28)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(visibleSessions) { summary in
                    threadGroup(for: summary, children: snapshot.childrenByParent[summary.id] ?? [])
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                HStack(spacing: 0) {
                    if hiddenThreadCount > 0 {
                        threadLimitButton(snapshot: snapshot, hiddenThreadCount: hiddenThreadCount, collapse: false)
                    }
                    if additionalVisibleThreadCount > 0 {
                        threadLimitButton(snapshot: snapshot, hiddenThreadCount: hiddenThreadCount, collapse: true)
                    }
                }
            }
        }
        .clipped()
        .task {
            await performance.monitor(project: project.id)
        }
        .onDisappear { performance.flush(project: project.id) }
        .animation(.easeInOut(duration: 0.18), value: expandedReviewParentIds)
        .sheet(item: $taskSheet) { payload in
            TaskFormSheet(payload: payload, defaultProjectId: project.id)
                .environment(appState)
                .environment(windowState)
        }
        .alert("Could Not Create Task", isPresented: $showTaskCreationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The chat has no readable messages, or the AI could not generate a task description. Try again later.")
        }
    }

    /// A top-level thread row plus, when expanded, its nested review children.
    @ViewBuilder
    private func threadGroup(for summary: ChatSession.Summary, children: [ChatSession.Summary]) -> some View {
        let isExpanded = expandedReviewParentIds.contains(summary.id)

        VStack(alignment: .leading, spacing: 0) {
            chatRow(for: summary, reviewDisclosure: disclosure(for: summary, children: children))

            if isExpanded {
                ForEach(childDisplayItems(children), id: \.summary.id) { item in
                    chatRow(
                        for: item.summary,
                        indentLevel: 1,
                        titleOverride: item.titleOverride,
                        showLabelChip: item.showLabelChip
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }
            }
        }
    }

    /// How a nested child row should render. Code-review children keep the
    /// `Review 1`, `Review 2`, … numbering (the nesting + number conveys what
    /// they are, so no chip). Other linked children — e.g. a Send Message hook's
    /// new thread — show their own title and keep their `threadLabel` chip so the
    /// user-chosen label is visible instead of a bogus "Review N".
    private struct ChildDisplayItem {
        let summary: ChatSession.Summary
        let titleOverride: String?
        let showLabelChip: Bool
    }

    private func childDisplayItems(_ children: [ChatSession.Summary]) -> [ChildDisplayItem] {
        var reviewNumber = 0
        return children.map { child in
            if child.threadLabel == AppState.manualCodeReviewLabel {
                reviewNumber += 1
                return ChildDisplayItem(summary: child, titleOverride: "Review \(reviewNumber)", showLabelChip: false)
            }
            return ChildDisplayItem(summary: child, titleOverride: nil, showLabelChip: true)
        }
    }

    private func disclosure(
        for summary: ChatSession.Summary,
        children: [ChatSession.Summary]
    ) -> ProjectChatRow.ReviewDisclosure? {
        guard !children.isEmpty else { return nil }
        let isReviewing = children.contains { child in
            if case .streaming = appState.chatStatus(forSessionId: child.id, in: windowState) {
                return true
            }
            return false
        }
        return ProjectChatRow.ReviewDisclosure(
            count: children.count,
            isExpanded: expandedReviewParentIds.contains(summary.id),
            isReviewing: isReviewing,
            onToggle: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expandedReviewParentIds.contains(summary.id) {
                        expandedReviewParentIds.remove(summary.id)
                    } else {
                        expandedReviewParentIds.insert(summary.id)
                    }
                }
            }
        )
    }

    private func threadLimitButton(snapshot: HistorySnapshot, hiddenThreadCount: Int, collapse: Bool) -> some View {
        Button {
            performance.flush(project: project.id)
            let nextAdditionalCount = collapse
                ? max(0, min(additionalVisibleThreadCount, snapshot.sessions.count - snapshot.collapsedVisibleCount) - 50)
                : additionalVisibleThreadCount + min(50, hiddenThreadCount)
            let nextVisibleCount = min(snapshot.sessions.count, snapshot.collapsedVisibleCount + nextAdditionalCount)
            performance.log("toggle project=\(project.id) collapse=\(collapse) visible=\(nextVisibleCount) remaining=\(snapshot.sessions.count - nextVisibleCount) projectThreads=\(snapshot.projectThreadCount)")
            let start = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                performance.log("toggle next main-queue turn project=\(project.id) delayMs=\(ChatHistoryPerformanceLog.elapsed(since: start)) (not render completion)")
            }
            // Bulk expansion should not animate hundreds of row transitions.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                additionalVisibleThreadCount = nextAdditionalCount
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapse ? "chevron.up" : "chevron.down")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    .frame(width: 12, height: 12)

                Text(collapse ? "Show fewer" : "Show more")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))

                if !collapse {
                    Text("\(min(50, hiddenThreadCount))")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .foregroundStyle(ClaudeTheme.textTertiary)
            .padding(.leading, 28)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapse ? "Hide up to 50 threads" : "Show the next \(min(50, hiddenThreadCount)) threads (\(hiddenThreadCount) remaining)")
    }

    private func chatRow(
        for summary: ChatSession.Summary,
        indentLevel: Int = 0,
        titleOverride: String? = nil,
        showLabelChip: Bool = true,
        reviewDisclosure: ProjectChatRow.ReviewDisclosure? = nil
    ) -> some View {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { performance.record("row-preparation", since: start, project: project.id) }
        let sessionId = summary.id
        let session = summary.makeSession()
        let status = appState.chatStatus(forSessionId: sessionId, in: windowState)
        let progress = appState.todoProgress(forSessionId: sessionId)
        let linkedTask = appState.linkedTask(forSessionId: sessionId, projectId: summary.projectId)

        return ProjectChatRow(
            summary: summary,
            isCurrent: windowState.generalRoute == nil && windowState.currentSessionId == sessionId,
            status: status,
            todoProgress: progress,
            linkedTask: linkedTask,
            isCreatingTask: creatingTaskSessionIds.contains(sessionId),
            onSelect: { onSelectSession(sessionId) },
            onOpenTask: {
                if let linkedTask { taskSheet = .task(linkedTask) }
            },
            onCreateTask: {
                guard creatingTaskSessionIds.insert(sessionId).inserted else { return }
                Task {
                    let created = await appState.createTaskFromChat(summary)
                    creatingTaskSessionIds.remove(sessionId)
                    if let created {
                        taskSheet = .task(created)
                    } else if let existing = appState.linkedTask(forSessionId: sessionId, projectId: summary.projectId) {
                        taskSheet = .task(existing)
                    } else {
                        showTaskCreationError = true
                    }
                }
            },
            onRename: { onRenameSession(session) },
            onTogglePin: {
                Task { await appState.togglePinSession(session) }
            },
            onToggleArchive: {
                if summary.isArchived {
                    Task {
                        await appState.unarchiveSession(session, in: windowState)
                    }
                } else {
                    onArchiveSession(session)
                }
            },
            onDelete: {
                onDeleteSession(session)
            },
            onCodeReview: {
                Task {
                    if let threadId = try? await appState.createCodeReviewForThread(sessionId: sessionId) {
                        appState.selectSession(id: threadId, in: windowState)
                    }
                }
            },
            onCommitFiles: {
                Task {
                    if let threadId = try? await appState.commitFilesForThread(sessionId: sessionId) {
                        appState.selectSession(id: threadId, in: windowState)
                    }
                }
            },
            hookMenuItems: { appState.threadContextMenuItems(for: summary) },
            indentLevel: indentLevel,
            titleOverride: titleOverride,
            showLabelChip: showLabelChip,
            reviewDisclosure: reviewDisclosure,
            reviewPassed: appState.reviewPassedBySession[sessionId],
            canCommitFiles: appState.threadHasFileChanges(sessionId: sessionId)
        )
    }
}
