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
    /// Plan groups start expanded. Other linked thread groups start collapsed.
    @State private var toggledParentIDs: Set<String> = []

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
        // A new or pinned implementation brings its whole plan into view.
        let roots = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenRoots: Set<String> = []
        sessions = allSessions.compactMap { summary in
            let root = summary.implementationParentID.flatMap { roots[$0] } ?? roots[summary.id]
            guard let root, seenRoots.insert(root.id).inserted else { return nil }
            return root
        }
        childrenByParent = childrenByParent.mapValues { $0.sorted { $0.updatedAt < $1.updatedAt } }
        performance.record("child-grouping", since: groupingStart, project: project.id)

        let pinnedCount = sessions.prefix { root in
            root.isPinned || childrenByParent[root.id, default: []].contains { $0.isPinned && $0.implementationParentID == root.id }
        }.count
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
                    threadGroup(for: summary, childrenByParent: snapshot.childrenByParent)
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
        .onChange(of: windowState.currentSessionId) { _, id in
            if let parent = appState.allSessionSummaries.first(where: { $0.id == id })?.implementationParentID {
                toggledParentIDs.remove(parent)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toggledParentIDs)
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

    private func threadGroup(for root: ChatSession.Summary, childrenByParent: [String: [ChatSession.Summary]]) -> some View {
        var rows: [(item: ChildDisplayItem, depth: Int)] = []
        func append(_ item: ChildDisplayItem, depth: Int) {
            rows.append((item, depth))
            let children = childrenByParent[item.summary.id] ?? []
            guard isExpanded(item.summary.id, children: children) else { return }
            for child in childDisplayItems(children) { append(child, depth: depth + 1) }
        }
        append(ChildDisplayItem(summary: root, titleOverride: nil, showLabelChip: true), depth: 0)
        return ForEach(rows, id: \.item.summary.id) { row in
            let item = row.item
            chatRow(for: item.summary, indentLevel: row.depth, titleOverride: item.titleOverride,
                    showLabelChip: item.showLabelChip,
                    reviewDisclosure: disclosure(for: item.summary, children: childrenByParent[item.summary.id] ?? []))
        }
    }

    private func isExpanded(_ id: String, children: [ChatSession.Summary]) -> Bool {
        let planGroup = children.contains { $0.implementationParentID == id }
        return planGroup != toggledParentIDs.contains(id)
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
            isExpanded: isExpanded(summary.id, children: children),
            isReviewing: isReviewing,
            onToggle: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if toggledParentIDs.contains(summary.id) {
                        toggledParentIDs.remove(summary.id)
                    } else {
                        toggledParentIDs.insert(summary.id)
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
        let status = appState.chatStatus(forSessionId: sessionId, in: windowState)
        let progress = status == .streaming ? appState.todoProgress(forSessionId: sessionId) : nil
        let linkedTask = appState.linkedTask(forSessionId: sessionId, projectId: summary.projectId)

        return ProjectChatRow(
            summary: summary,
            isCurrent: windowState.sidebarTreeSelection == .thread(sessionId),
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
            onRename: { onRenameSession(summary.makeSession()) },
            onTogglePin: {
                Task { await appState.togglePinSession(summary.makeSession()) }
            },
            onToggleArchive: {
                if summary.isArchived {
                    Task {
                        await appState.unarchiveSession(summary.makeSession(), in: windowState)
                    }
                } else {
                    onArchiveSession(summary.makeSession())
                }
            },
            onDelete: {
                onDeleteSession(summary.makeSession())
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
            hasFileChanges: appState.threadHasDiffPreview(sessionId: sessionId),
            pullRequest: appState.pullRequest(forThread: summary, in: project)
        )
    }
}
