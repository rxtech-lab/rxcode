import RxCodeCore
import RxCodeSync
import SwiftUI

enum MobileDraftSessionID {
    private static let prefix = "draft-new"

    static func make(projectID: UUID) -> String {
        "\(prefix):\(projectID.uuidString):\(UUID().uuidString)"
    }

    static func projectID(from id: String) -> UUID? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func isDraft(_ id: String) -> Bool {
        projectID(from: id) != nil
    }
}

struct SessionsList: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let projectID: UUID
    @Binding var selected: String?
    var usesSelection = true
    @State private var searchText = ""
    @State private var showingNewThread = false
    @State private var showingDeleteProjectConfirm = false
    @State private var showingSearch = false
    @State private var isCreatingPR = false
    @State private var isCreatingReview = false
    @State private var isCommittingProject = false
    @Namespace private var glassNamespace

    // Autopilot actions (1:1 with the desktop project menu), moved here from the
    // project list card so they live in the project detail toolbar.
    @State private var autopilotStatus: AutopilotProjectStatus?
    @State private var showingSecretsDownload = false
    @State private var showingReleaseCreate = false
    @State private var autopilotSetupChat: AutopilotSetupChat?
    @State private var autopilotInfo: AutopilotMenuInfo?

    private var project: Project? {
        state.projects.first { $0.id == projectID }
    }

    /// Current branch resolved on the desktop for this project.
    private var currentBranch: String? {
        state.projectBranches[projectID]
    }

    /// CI/PR status for the project's current branch, used to gate "Create PR".
    private var ciStatus: ProjectCIStatus? {
        state.ciStatusByProject[projectID]
    }

    /// Number of rows currently materialized. The list grows in `pageSize`
    /// increments as the user scrolls so we never render every thread at once.
    @State private var displayLimit = SessionsList.pageSize
    private static let pageSize = 20

    /// Parent thread ids whose nested review children are currently expanded.
    @State private var expandedReviewParentIds: Set<String> = []

    var body: some View {
        glassThreadList
            .navigationTitle("Threads")
            .toolbar { toolbarContent }
            .toolbar(usesSelection ? .automatic : .hidden, for: .tabBar)
            .toolbar {
                // Show search button in bottom bar on iPhone when tab bar is hidden
                if !usesSelection {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingSearch) {
                FullScreenSearchView(isPresented: $showingSearch)
                    .environmentObject(state)
            }
            .sheet(isPresented: $showingNewThread) {
                NewThreadSheet(projectID: projectID) { newSessionID in
                    selected = newSessionID
                }
                .environmentObject(state)
                .mobileSheetPresentation()
            }
            .modifier(SessionsListSearchModifier(
                isEnabled: usesSelection, // Only show search on iPad (usesSelection=true)
                searchText: $searchText,
                displayLimit: $displayLimit,
                pageSize: Self.pageSize,
                state: state
            ))
            .overlay {
                if usesDesktopSearch, !state.isSearching, desktopSearchHits.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if !usesDesktopSearch, filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filtered.isEmpty && searchText.isEmpty {
                    emptyStateView
                }
            }
            .projectAutopilotMenuHost(
                project: project,
                status: $autopilotStatus,
                showDownloadSheet: $showingSecretsDownload,
                showReleaseCreate: $showingReleaseCreate,
                setupChat: $autopilotSetupChat,
                info: $autopilotInfo,
                state: state
            )
            .confirmationDialog(
                "Delete Project?",
                isPresented: $showingDeleteProjectConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive) {
                    Task {
                        await state.deleteProject(projectID: projectID)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes “\(project?.name ?? "this project")” and all its threads from RxCode. Your files on the Mac are not deleted.")
            }
            .mobileAutopilotLoadingDialog(
                isCreatingPR,
                title: "Creating Pull Request…",
                message: "The Mac is pushing the branch and opening the PR."
            )
            .mobileAutopilotLoadingDialog(
                isCreatingReview,
                title: "Starting Code Review…",
                message: "The Mac is starting a Code Review thread for this branch."
            )
            .mobileAutopilotLoadingDialog(
                isCommittingProject,
                title: "Committing Changes…",
                message: "The Mac is starting a commit thread for this project."
            )
    }

    /// Ask the Mac to open a PR for the project's current branch, then open it
    /// in the browser (mirrors the desktop briefing "Create PR" button).
    private func createPullRequest(project: Project, branch: String) {
        guard !isCreatingPR else { return }
        isCreatingPR = true
        Task {
            defer { isCreatingPR = false }
            do {
                let url = try await state.requestProjectCreatePullRequest(
                    projectId: project.id,
                    branch: branch
                )
                await state.refreshSnapshot()
                openURL(url)
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Ask the Mac to start a `[Code Review]` thread reviewing the project's
    /// current branch (grounded in its briefing), then open it once it syncs.
    private func createBranchCodeReview(project: Project, branch: String) {
        guard !isCreatingReview else { return }
        isCreatingReview = true
        Task {
            defer { isCreatingReview = false }
            do {
                let threadId = try await state.requestProjectCreateCodeReview(
                    projectId: project.id,
                    branch: branch
                )
                await state.refreshSnapshot()
                selected = threadId
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Ask the Mac to start a `[Code Review]` thread reviewing a single thread's
    /// changes (the manual equivalent of the built-in Code Review hook).
    private func createThreadCodeReview(sessionID: String) {
        Task {
            do {
                let threadId = try await state.requestThreadCreateCodeReview(sessionId: sessionID)
                await state.refreshSnapshot()
                selected = threadId
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Ask the Mac to start a commit-only thread for all project changes, then
    /// open it once it syncs.
    private func commitProjectChanges(project: Project) {
        guard !isCommittingProject else { return }
        isCommittingProject = true
        Task {
            defer { isCommittingProject = false }
            do {
                let threadId = try await state.requestProjectCommitAll(projectId: project.id)
                await state.refreshSnapshot()
                selected = threadId
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// Ask the Mac to commit only the files recorded for a single thread.
    private func commitThreadFiles(sessionID: String) {
        Task {
            do {
                let threadId = try await state.requestThreadCommitFiles(sessionId: sessionID)
                await state.refreshSnapshot()
                selected = threadId
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let project {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ProjectAutopilotMenuItems(
                        project: project,
                        status: autopilotStatus,
                        showDownloadSheet: $showingSecretsDownload,
                        showReleaseCreate: $showingReleaseCreate,
                        setupChat: $autopilotSetupChat,
                        info: $autopilotInfo,
                        branch: currentBranch,
                        prNumber: ciStatus?.prNumber,
                        isCreatingPR: isCreatingPR,
                        onCreatePR: {
                            if let branch = currentBranch {
                                createPullRequest(project: project, branch: branch)
                            }
                        },
                        isCreatingReview: isCreatingReview,
                        onCodeReview: {
                            if let branch = currentBranch {
                                createBranchCodeReview(project: project, branch: branch)
                            }
                        },
                        isCommittingAll: isCommittingProject,
                        onCommitAll: {
                            commitProjectChanges(project: project)
                        }
                    )
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteProjectConfirm = true
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                }
                .accessibilityLabel("Project actions")
                .accessibilityIdentifier("project-actions-\(projectID.uuidString)")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingNewThread = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
            }
        }
    }

    // MARK: - Glass Thread List

    private var glassThreadList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if usesDesktopSearch {
                    desktopSearchResults
                } else {
                    GlassEffectContainer(spacing: 12) {
                        ForEach(visible) { session in
                            threadGroup(for: session)
                        }
                    }

                    if displayLimit < topLevelFiltered.count {
                        loadingIndicator
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.spring(duration: 0.3), value: filtered.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: expandedReviewParentIds)
        .accessibilityIdentifier("thread-list-screen")
    }

    @ViewBuilder
    private var desktopSearchResults: some View {
        if state.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if !desktopSearchHits.isEmpty {
            GlassEffectContainer(spacing: 12) {
                ForEach(desktopSearchHits) { hit in
                    SearchThreadHitCard(
                        hit: hit,
                        project: projectsByID[hit.projectID],
                        namespace: glassNamespace
                    )
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func threadContextMenu(for session: SessionSummary) -> some View {
        Button {
            createThreadCodeReview(sessionID: session.id)
        } label: {
            Label("Code Review", systemImage: "checklist")
        }

        Button {
            commitThreadFiles(sessionID: session.id)
        } label: {
            Label("Commit Files", systemImage: "checkmark.circle")
        }

        Button {
            Task { await state.archiveThread(sessionID: session.id) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }

        Divider()

        Button(role: .destructive) {
            Task { await state.deleteThread(sessionID: session.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Loading Indicator

    private var loadingIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .padding(.vertical, 20)
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No Threads")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Start a new conversation to get help with your project.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingNewThread = true
            } label: {
                Label("New Thread", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The slice of top-level threads currently rendered.
    private var visible: [SessionSummary] {
        Array(topLevelFiltered.prefix(displayLimit))
    }

    /// Top-level threads only — review children (`parentThreadId` pointing at a
    /// thread that is also in this list) are nested under their parent. A child
    /// whose parent isn't here falls back to the top level so it's never hidden.
    private var topLevelFiltered: [SessionSummary] {
        let ids = Set(filtered.map(\.id))
        return filtered.filter { session in
            guard let parent = session.parentThreadId else { return true }
            return !ids.contains(parent)
        }
    }

    /// Review children grouped by their parent thread id, oldest first so they
    /// number naturally as `Review 1`, `Review 2`, …
    private var childrenByParent: [String: [SessionSummary]] {
        let ids = Set(filtered.map(\.id))
        let children = filtered.filter { session in
            guard let parent = session.parentThreadId else { return false }
            return ids.contains(parent)
        }
        return Dictionary(grouping: children, by: { $0.parentThreadId! })
            .mapValues { $0.sorted { $0.updatedAt < $1.updatedAt } }
    }

    /// A top-level thread row. When it owns review children, an in-card leading
    /// disclosure control (chevron + count) toggles the nested reviews — mirrors
    /// Android's `SessionCard`. Every card stays full-width and left-aligned.
    @ViewBuilder
    private func threadGroup(for session: SessionSummary) -> some View {
        let children = childrenByParent[session.id] ?? []
        let isExpanded = expandedReviewParentIds.contains(session.id)

        threadCard(for: session, reviewChildren: children, isReviewExpanded: isExpanded)

        if isExpanded {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                threadCard(for: child, indentLevel: 1, titleOverride: "Review \(index + 1)")
            }
        }
    }

    private func threadCard(
        for session: SessionSummary,
        indentLevel: Int = 0,
        titleOverride: String? = nil,
        reviewChildren: [SessionSummary] = [],
        isReviewExpanded: Bool = false
    ) -> some View {
        GlassThreadCard(
            session: session,
            isSelected: selected == session.id,
            usesNavigationLink: !usesSelection,
            onSelect: usesSelection ? { selected = session.id } : nil,
            indentLevel: indentLevel,
            titleOverride: titleOverride,
            showLabelChip: indentLevel == 0,
            reviewCount: reviewChildren.count,
            isReviewExpanded: isReviewExpanded,
            isReviewStreaming: reviewChildren.contains { $0.isStreaming },
            onToggleReviews: reviewChildren.isEmpty ? nil : { toggleReviews(for: session.id) }
        )
        .glassEffectID(session.id, in: glassNamespace)
        .onAppear {
            if indentLevel == 0, session.id == visible.last?.id { loadMore() }
        }
        .contextMenu {
            threadContextMenu(for: session)
        }
    }

    private func toggleReviews(for parentID: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedReviewParentIds.contains(parentID) {
                expandedReviewParentIds.remove(parentID)
            } else {
                expandedReviewParentIds.insert(parentID)
            }
        }
    }

    private var usesDesktopSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var desktopSearchHits: [SearchHit] {
        state.searchThreadHits
    }

    private var projectsByID: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    private func loadMore() {
        guard displayLimit < topLevelFiltered.count else { return }
        displayLimit = min(displayLimit + Self.pageSize, topLevelFiltered.count)
    }

    private var filtered: [SessionSummary] {
        let query = searchText.lowercased()
        return state.sessions
            .filter { session in
                guard session.projectId == projectID, !session.isArchived else { return false }
                if query.isEmpty { return true }
                let title = ChatSession.stripAttachmentMarkers(from: session.title).lowercased()
                return title.contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
}

// MARK: - Previews

#if DEBUG
extension MobileAppState {
    /// A preview-ready MobileAppState with sample projects and sessions.
    static var preview: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()

        state.projects = [
            Project(id: projectID, name: "RxCode", path: "/Users/dev/RxCode")
        ]

        state.sessions = [
            SessionSummary(
                id: "session-1",
                projectId: projectID,
                title: "Building new feature module",
                updatedAt: Date(),
                isPinned: false,
                isArchived: false,
                isStreaming: true,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Create models", activeForm: "Creating models", status: .completed),
                    TodoItem(id: 2, content: "Add views", activeForm: "Adding views", status: .inProgress),
                    TodoItem(id: 3, content: "Write tests", activeForm: "Writing tests", status: .pending)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-2",
                projectId: projectID,
                title: "Implement Liquid Glass UI",
                updatedAt: Date().addingTimeInterval(-300),
                isPinned: true,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Task 1", activeForm: "Doing task 1", status: .completed),
                    TodoItem(id: 2, content: "Task 2", activeForm: "Doing task 2", status: .completed),
                    TodoItem(id: 3, content: "Task 3", activeForm: "Doing task 3", status: .completed)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-3",
                projectId: projectID,
                title: "Deploy to production",
                updatedAt: Date().addingTimeInterval(-120),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .permission,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-4",
                projectId: projectID,
                title: "Code review assistance",
                updatedAt: Date().addingTimeInterval(-600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .question,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-5",
                projectId: projectID,
                title: "Fix scrolling performance",
                updatedAt: Date().addingTimeInterval(-3600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: true
            ),
            SessionSummary(
                id: "session-6",
                projectId: projectID,
                title: "Review pull request",
                updatedAt: Date().addingTimeInterval(-86400),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: false
            )
        ]

        return state
    }

    /// A preview-ready MobileAppState with no sessions (empty state).
    static var previewEmpty: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()

        state.projects = [
            Project(id: projectID, name: "New Project", path: "/Users/dev/NewProject")
        ]
        state.sessions = []

        return state
    }
}

#Preview("Sessions List") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - With Selection") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id
    let selectedID = state.sessions.first?.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(selectedID),
            usesSelection: true
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - Empty") {
    let state = MobileAppState.previewEmpty
    let projectID = state.projects.first!.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}
#endif

// MARK: - Search Modifier

private struct SessionsListSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String
    @Binding var displayLimit: Int
    let pageSize: Int
    let state: MobileAppState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Global search"
                )
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .onChange(of: searchText) { _, newValue in
                    // Restart paging so search results always begin at the top.
                    displayLimit = pageSize
                    state.updateSearchQuery(newValue)
                }
                .onDisappear {
                    state.updateSearchQuery("")
                }
        } else {
            content
        }
    }
}
