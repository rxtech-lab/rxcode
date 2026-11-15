import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?
    @Binding var showingBriefing: Bool
    var showsBriefingItem = true
    /// Selection binding for the Tasks sidebar item (iPad); the item is
    /// hidden when `nil`.
    var showingTasks: Binding<Bool>?
    /// Opens a project in a navigation stack (iPhone). When nil, tapping a
    /// project updates `selected` instead (iPad split view).
    var onOpenProject: ((UUID) -> Void)?
    @State private var searchText = ""
    @State private var showingRemoteFolderPicker = false
    @State private var showingGitHubRepoPicker = false

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MobileConnectionPathBadge()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addProjectMenu(iconOnly: true)
                    .popoverTip(MobileTips.RemoteProjectTip(), arrowEdge: .top)
                }
            }
            .sheet(isPresented: $showingRemoteFolderPicker) {
                RemoteFolderPickerView()
                    .environmentObject(state)
                    .mobileSheetPresentation()
            }
            .sheet(isPresented: $showingGitHubRepoPicker) {
                MobileAutopilotRepoPicker(
                    title: "Add Project",
                    existingRepoFullNames: existingGitHubRepoNames
                ) { repo in
                    try await state.cloneAutopilotRepo(repo)
                }
                .environmentObject(state)
                .mobileSheetPresentation()
            }
            .refreshable {
                await state.refreshSnapshot()
            }
            .task {
                await loadAutopilotAccountIfNeeded()
            }
            .onChange(of: state.connectionState) { _, _ in
                Task { await loadAutopilotAccountIfNeeded(force: true) }
            }
            .modifier(ProjectSidebarSearchModifier(isEnabled: showsSearch, searchText: $searchText))
            .modifier(ProjectSidebarSearchTipModifier(isEnabled: showsSearch))
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .onChange(of: searchText) { _, newValue in
                if showsSearch {
                    state.updateSearchQuery(newValue)
                }
            }
            .onDisappear {
                state.updateSearchQuery("")
            }
            .onChange(of: showsSearch) { _, newValue in
                if !newValue {
                    searchText = ""
                    state.updateSearchQuery("")
                }
            }
            .onChange(of: state.lastCreatedProjectID) { _, newValue in
                guard let newValue else { return }
                // Don't auto-select/navigate to a freshly added project — just
                // surface it in the list. The user opens it when they choose to.
                AnalyticsService.shared.log(.newProjectStarted, parameters: [
                    "project_id": newValue.uuidString,
                ])
            }
            .onChange(of: selected) { _, newValue in
                guard let newValue else { return }
                AnalyticsService.shared.log(.projectOpened, parameters: [
                    "project_id": newValue.uuidString,
                ])
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !showsSearch || searchText.isEmpty {
            defaultContent
        } else {
            searchResultsContent
        }
    }

    // MARK: - Default Content

    @ViewBuilder
    private var defaultContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let showingTasks {
                    SidebarNavigationCard(
                        title: "Tasks",
                        subtitle: "Stories and tasks across projects",
                        systemImage: "checklist",
                        tint: .teal,
                        isSelected: showingTasks.wrappedValue
                    ) {
                        selected = nil
                        showingBriefing = false
                        showingTasks.wrappedValue = true
                    }
                    .accessibilityIdentifier("sidebar-tasks")
                }

                // Briefing Card
                if showsBriefingItem {
                    SidebarNavigationCard(
                        title: "Briefing",
                        subtitle: "Daily summary of your projects",
                        systemImage: "doc.text.fill",
                        tint: .indigo,
                        isSelected: showingBriefing
                    ) {
                        selected = nil
                        showingTasks?.wrappedValue = false
                        showingBriefing = true
                    }
                    .popoverTip(MobileTips.BriefingTip(), arrowEdge: .trailing)
                    .accessibilityIdentifier("sidebar-briefing")

                    if showingTasks != nil {
                        Divider()
                            .padding(.horizontal, 4)
                    }
                }

                // Projects Section
                if !state.projects.isEmpty {
                    Group {
                        ForEach(state.projects) { project in
                            ProjectCard(
                                project: project,
                                threadCount: threadCount(for: project.id),
                                activeJobCount: activeJobCount(for: project.id),
                                lastActivity: lastActivity(for: project.id),
                                isSelected: onOpenProject == nil && selected == project.id,
                                onSelect: { open(project) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(MobileCard.pageBackground)
        .overlay {
            if state.projects.isEmpty { emptyProjectsView }
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.spring(duration: 0.3), value: state.projects.map(\.id))
    }

    // MARK: - Search Results Content

    @ViewBuilder
    private var searchResultsContent: some View {
        let projectMatches = state.projects.filter { project in
            state.searchProjectIDs.contains(project.id)
        }
        let threadHits = state.searchThreadHits
        let projectsByID = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })

        ScrollView {
            LazyVStack(spacing: 16) {
                if projectMatches.isEmpty && threadHits.isEmpty {
                    if state.isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    }
                } else {
                    // Project matches
                    if !projectMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Projects")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)

                            VStack(spacing: 10) {
                                ForEach(projectMatches) { project in
                                    ProjectCard(
                                        project: project,
                                        threadCount: threadCount(for: project.id),
                                        activeJobCount: activeJobCount(for: project.id),
                                        lastActivity: lastActivity(for: project.id),
                                        isSelected: onOpenProject == nil && selected == project.id,
                                        onSelect: { open(project) }
                                    )
                                }
                            }
                        }
                    }

                    // Thread matches
                    if !threadHits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Threads")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)

                            VStack(spacing: 10) {
                                ForEach(threadHits) { hit in
                                    SearchThreadHitCard(
                                        hit: hit,
                                        project: projectsByID[hit.projectID]
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(MobileCard.pageBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Empty State

    private var emptyProjectsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No Projects")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Add a project from your Mac to get started.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            addProjectMenu(iconOnly: false)
                .font(.subheadline.weight(.medium))
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var showsSearch: Bool {
        // Search is now handled by the dedicated search tab on iPhone
        false
    }

    private var canAddFromRemoteRepositories: Bool {
        state.isPaired
            && state.connectionState == .connected
            && state.autopilotAccount?.isSignedIn == true
    }

    private var existingGitHubRepoNames: Set<String> {
        Set(state.projects.compactMap { $0.gitHubRepo?.lowercased() })
    }

    @ViewBuilder
    private func addProjectMenu(iconOnly: Bool) -> some View {
        Menu {
            Button {
                showingRemoteFolderPicker = true
            } label: {
                Label("Add project locally", systemImage: "folder.badge.plus")
            }

            if canAddFromRemoteRepositories {
                Button {
                    showingGitHubRepoPicker = true
                } label: {
                    Label("Add project from remote repositories", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: "plus")
            } else {
                Label("Add Project", systemImage: "plus")
            }
        }
        .accessibilityLabel("Add Project")
    }

    private func open(_ project: Project) {
        if let onOpenProject {
            onOpenProject(project.id)
        } else {
            selected = project.id
            showingBriefing = false
        }
    }

    private func loadAutopilotAccountIfNeeded(force: Bool = false) async {
        guard state.isPaired, state.connectionState == .connected else { return }
        if !force, state.autopilotAccount != nil { return }
        _ = try? await state.loadAutopilotAccount()
    }

    private func threadCount(for projectID: UUID) -> Int {
        state.sessionListIndex.projects[projectID]?.threadCount ?? 0
    }

    private func activeJobCount(for projectID: UUID) -> Int {
        state.sessionListIndex.projects[projectID]?.activeJobCount ?? 0
    }

    private func lastActivity(for projectID: UUID) -> Date? {
        state.sessionListIndex.projects[projectID]?.lastActivity
    }

    private static func truncatedPath(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let afterUsers = path.dropFirst("/Users/".count)
        guard let slash = afterUsers.firstIndex(of: "/") else { return path }
        return "~" + afterUsers[slash...]
    }
}

private struct ProjectSidebarSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search projects and threads"
            )
        } else {
            content
        }
    }
}

private struct ProjectSidebarSearchTipModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.popoverTip(MobileTips.SearchTip(), arrowEdge: .top)
        } else {
            content
        }
    }
}

// MARK: - Sidebar Navigation Card

/// A full-width card for a top-level sidebar destination (Briefing, Tasks)
/// above the project list.
private struct SidebarNavigationCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    var onSelect: (() -> Void)?

    var body: some View {
        MobileRowButton { onSelect?() } label: { cardContent }
            .buttonStyle(MobileCardButtonStyle(isSelected: isSelected))
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            MobileCardIconTile(systemImage: systemImage, tint: tint, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    let project: Project
    let threadCount: Int
    let activeJobCount: Int
    let lastActivity: Date?
    let isSelected: Bool
    var onSelect: (() -> Void)?

    var body: some View {
        // The autopilot actions live in the project detail (thread list)
        // toolbar, so the project card is a plain navigation row.
        // The UI-test identifier is applied directly on the button. Applied to
        // an enclosing container, it doesn't reach the button XCUITest queries.
        MobileRowButton {
            onSelect?()
        } label: {
            cardContent
        }
        .buttonStyle(MobileCardButtonStyle(
            isSelected: isSelected,
            rail: activeJobCount > 0 ? ClaudeTheme.statusSuccess : nil
        ))
        .accessibilityIdentifier("project-row-\(project.id.uuidString)")
        .projectRemoteContextMenu(project: project)
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            monogram

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if let lastActivity {
                        Text(compactElapsed(since: lastActivity))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(Self.truncatedPath(project.path))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if threadCount > 0 || activeJobCount > 0 {
                    // FlowLayout wraps gracefully on narrow sidebars.
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        if threadCount > 0 {
                            MobileCardTag(
                                text: "\(threadCount)",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        }
                        if activeJobCount > 0 {
                            MobileCardTag(
                                text: String(localized: "\(activeJobCount) active"),
                                systemImage: "circle.fill",
                                tint: ClaudeTheme.statusSuccess
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.leading, activeJobCount > 0 ? 18 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Initial-letter tile with a stable per-project hue.
    private var monogram: some View {
        let hue = Double(abs(project.id.uuidString.hashValueStable) % 360) / 360
        let tint = Color(hue: hue, saturation: 0.55, brightness: 0.8)
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 40, height: 40)
            .overlay {
                Text(project.name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
    }

    private static func truncatedPath(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let afterUsers = path.dropFirst("/Users/".count)
        guard let slash = afterUsers.firstIndex(of: "/") else { return path }
        return "~" + afterUsers[slash...]
    }

    private func compactElapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}

private extension String {
    /// Deterministic across launches (unlike `hashValue`), so a project keeps
    /// its colour.
    var hashValueStable: Int {
        unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }
}

// MARK: - Search Thread Hit Card

struct SearchThreadHitCard: View {
    let hit: SearchHit
    let project: Project?

    private var title: String {
        hit.title.isEmpty ? ChatSession.defaultTitle : hit.title
    }

    private var showSnippet: Bool {
        !hit.snippet.isEmpty && hit.snippet != title
    }

    var body: some View {
        NavigationLink(value: hit.sessionID) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIconTile(systemImage: "bubble.left.fill", tint: ClaudeTheme.accent, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showSnippet {
                        Text(hit.snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let project {
                        Label(project.name, systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MobileCardButtonStyle())
    }
}

// MARK: - Preview

#Preview("Projects Sidebar") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    let projectIDs = [UUID(), UUID(), UUID()]

    state.projects = [
        Project(
            id: projectIDs[0],
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        ),
        Project(
            id: projectIDs[1],
            name: "MyApp",
            path: "/Users/developer/Projects/MyApp"
        ),
        Project(
            id: projectIDs[2],
            name: "SwiftPackage",
            path: "/Users/developer/Code/SwiftPackage"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectIDs[0],
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "2",
            projectId: projectIDs[0],
            title: "Fix bug",
            updatedAt: Date().addingTimeInterval(-3600),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "3",
            projectId: projectIDs[1],
            title: "Review PR",
            updatedAt: Date().addingTimeInterval(-86400),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - Empty") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    state.projects = []

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - Selected") {
    @Previewable @State var showingBriefing = false
    @Previewable @State var selected: UUID? = nil

    let state = MobileAppState()
    let projectID = UUID()

    state.projects = [
        Project(
            id: projectID,
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectID,
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "2",
            projectId: projectID,
            title: "Another thread",
            updatedAt: Date().addingTimeInterval(-600),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: .constant(projectID),
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - iPhone (Stack)") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    let projectIDs = [UUID(), UUID()]

    state.projects = [
        Project(
            id: projectIDs[0],
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        ),
        Project(
            id: projectIDs[1],
            name: "MyApp",
            path: "/Users/developer/Projects/MyApp"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectIDs[0],
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing,
            showsBriefingItem: false,
            onOpenProject: { selected = $0 }
        )
    }
    .environmentObject(state)
}
