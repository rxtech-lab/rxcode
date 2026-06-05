import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?
    @Binding var showingBriefing: Bool
    var showsBriefingItem = true
    /// When true, uses Button with selection callback (iPad split view).
    /// When false, uses NavigationLink for stack-based navigation (iPhone).
    var usesSelection = true
    @State private var searchText = ""
    @State private var showingRemoteFolderPicker = false
    @State private var showingGitHubRepoPicker = false
    @Namespace private var glassNamespace

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar {
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

    // MARK: - Default Content (Glass Cards)

    @ViewBuilder
    private var defaultContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Briefing Card
                if showsBriefingItem {
                    BriefingNavigationCard(
                        isSelected: showingBriefing,
                        usesNavigationLink: false, // Briefing always uses callback
                        namespace: glassNamespace
                    ) {
                        selected = nil
                        showingBriefing = true
                    }
                    .popoverTip(MobileTips.BriefingTip(), arrowEdge: .trailing)
                }

                // Projects Section
                if !state.projects.isEmpty {
                    GlassEffectContainer(spacing: 12) {
                        ForEach(state.projects) { project in
                            GlassProjectCard(
                                project: project,
                                threadCount: threadCount(for: project.id),
                                activeJobCount: activeJobCount(for: project.id),
                                lastActivity: lastActivity(for: project.id),
                                isSelected: selected == project.id,
                                usesNavigationLink: !usesSelection,
                                namespace: glassNamespace,
                                onSelect: usesSelection ? {
                                    selected = project.id
                                    showingBriefing = false
                                } : nil
                            )
                        }
                    }
                } else {
                    emptyProjectsView
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

                            GlassEffectContainer(spacing: 10) {
                                ForEach(projectMatches) { project in
                                    GlassProjectCard(
                                        project: project,
                                        threadCount: threadCount(for: project.id),
                                        activeJobCount: activeJobCount(for: project.id),
                                        lastActivity: lastActivity(for: project.id),
                                        isSelected: selected == project.id,
                                        usesNavigationLink: !usesSelection,
                                        namespace: glassNamespace,
                                        onSelect: usesSelection ? {
                                            selected = project.id
                                            showingBriefing = false
                                        } : nil
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

                            GlassEffectContainer(spacing: 10) {
                                ForEach(threadHits) { hit in
                                    SearchThreadHitCard(
                                        hit: hit,
                                        project: projectsByID[hit.projectID],
                                        namespace: glassNamespace
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
            .buttonStyle(.glass)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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

    private func loadAutopilotAccountIfNeeded(force: Bool = false) async {
        guard state.isPaired, state.connectionState == .connected else { return }
        if !force, state.autopilotAccount != nil { return }
        _ = try? await state.loadAutopilotAccount()
    }

    private func threadCount(for projectID: UUID) -> Int {
        state.sessions.filter { $0.projectId == projectID && !$0.isArchived }.count
    }

    private func activeJobCount(for projectID: UUID) -> Int {
        state.sessions.filter { $0.projectId == projectID && $0.isStreaming }.count
    }

    private func lastActivity(for projectID: UUID) -> Date? {
        state.sessions
            .filter { $0.projectId == projectID }
            .map(\.updatedAt)
            .max()
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

// MARK: - Briefing Navigation Card

private struct BriefingNavigationCard: View {
    let isSelected: Bool
    var usesNavigationLink: Bool = false
    let namespace: Namespace.ID
    var onSelect: (() -> Void)?

    var body: some View {
        if usesNavigationLink {
            // Not used for briefing, but keeping pattern consistent
            Button { onSelect?() } label: { cardContent }
                .buttonStyle(GlassProjectCardButtonStyle(isSelected: isSelected))
                .glassEffectID("briefing", in: namespace)
        } else {
            Button { onSelect?() } label: { cardContent }
                .buttonStyle(GlassProjectCardButtonStyle(isSelected: isSelected))
                .glassEffectID("briefing", in: namespace)
        }
    }

    private var cardContent: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(briefingGradient.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: "doc.text.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(briefingGradient)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Briefing")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Daily summary of your projects")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var briefingGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.4, green: 0.6, blue: 0.9),
                Color(red: 0.5, green: 0.4, blue: 0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Glass Project Card

private struct GlassProjectCard: View {
    let project: Project
    let threadCount: Int
    let activeJobCount: Int
    let lastActivity: Date?
    let isSelected: Bool
    /// When true, uses NavigationLink for stack-based navigation (iPhone).
    /// When false, uses Button with onSelect callback for selection-based navigation (iPad).
    var usesNavigationLink: Bool = true
    let namespace: Namespace.ID
    var onSelect: (() -> Void)?

    var body: some View {
        // The autopilot actions now live in the project detail (thread list)
        // toolbar — the project card is a plain navigation row.
        cardButton
    }

    @ViewBuilder
    private var cardButton: some View {
        // The UI-test identifier is applied directly on the button of each
        // branch — applying it to an enclosing container does not reach the
        // button element XCUITest queries.
        if usesNavigationLink {
            NavigationLink(value: project.id) {
                cardContent
            }
            .buttonStyle(GlassProjectCardButtonStyle(isSelected: isSelected))
            .glassEffectID(project.id.uuidString, in: namespace)
            .accessibilityIdentifier("project-row-\(project.id.uuidString)")
            .projectRemoteContextMenu(project: project)
        } else {
            Button {
                onSelect?()
            } label: {
                cardContent
            }
            .buttonStyle(GlassProjectCardButtonStyle(isSelected: isSelected))
            .glassEffectID(project.id.uuidString, in: namespace)
            .accessibilityIdentifier("project-row-\(project.id.uuidString)")
            .projectRemoteContextMenu(project: project)
        }
    }

    private var cardContent: some View {
        HStack(spacing: 14) {
            // Project icon
            projectIcon

            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Title
                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Path
                Text(Self.truncatedPath(project.path))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                // Metadata row - uses FlowLayout to wrap gracefully on narrow sidebars
                FlowLayout(spacing: 8) {
                    // Thread count
                    if threadCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 10, weight: .medium))
                            Text("\(threadCount)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Active jobs
                    if activeJobCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("\(activeJobCount) active")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    }

                    // Last activity
                    if let lastActivity {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(compactElapsed(since: lastActivity))
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var projectIcon: some View {
        ZStack {
            Circle()
                .fill(accentGradient.opacity(0.15))
                .frame(width: 44, height: 44)

            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accentGradient)
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.6, blue: 0.4),
                Color(red: 0.85, green: 0.5, blue: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

// MARK: - Search Thread Hit Card

struct SearchThreadHitCard: View {
    let hit: SearchHit
    let project: Project?
    let namespace: Namespace.ID

    private var title: String {
        hit.title.isEmpty ? ChatSession.defaultTitle : hit.title
    }

    private var showSnippet: Bool {
        !hit.snippet.isEmpty && hit.snippet != title
    }

    var body: some View {
        NavigationLink(value: hit.sessionID) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showSnippet {
                        Text(hit.snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let project {
                        Text(project.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
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
        .buttonStyle(GlassProjectCardButtonStyle(isSelected: false))
        .glassEffectID("search-\(hit.sessionID)", in: namespace)
    }
}

// MARK: - Glass Project Card Button Style

private struct GlassProjectCardButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .glassEffect(
                glassConfig(isPressed: configuration.isPressed),
                in: .rect(cornerRadius: 16)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected {
            return ClaudeTheme.accent.opacity(0.15)
        } else if isPressed {
            return Color.primary.opacity(0.05)
        } else {
            return .clear
        }
    }

    private func glassConfig(isPressed: Bool) -> Glass {
        if isSelected {
            return .regular.tint(ClaudeTheme.accent.opacity(0.3)).interactive()
        } else {
            return .regular.interactive()
        }
    }
}

// MARK: - Flow Layout

/// A layout that arranges views horizontally and wraps to the next line when needed.
/// Used for metadata rows that need to adapt to narrow sidebar widths on iPad.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layout(sizes: sizes, containerWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = layout(sizes: sizes, containerWidth: bounds.width).offsets

        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + offsets[index].x, y: bounds.minY + offsets[index].y),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func layout(sizes: [CGSize], containerWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for size in sizes {
            if currentX + size.width > containerWidth && currentX > 0 {
                // Wrap to next line
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (offsets, CGSize(width: maxWidth, height: currentY + lineHeight))
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

#Preview("Projects Sidebar - iPhone (NavigationLink)") {
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
            usesSelection: false
        )
        .navigationDestination(for: UUID.self) { projectID in
            Text("Sessions for project \(projectID)")
        }
    }
    .environmentObject(state)
}
