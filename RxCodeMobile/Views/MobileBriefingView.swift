import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import TipKit

struct BriefingGroupKey: Hashable {
    let projectId: UUID
    let branch: String
}

struct GroupedBriefing: Identifiable {
    let projectId: UUID
    let branch: String
    let briefing: MobileBranchBriefing?
    let threads: [MobileThreadSummary]
    let updatedAt: Date

    var id: String { "\(projectId.uuidString)::\(branch)" }
    var key: BriefingGroupKey { BriefingGroupKey(projectId: projectId, branch: branch) }
}

/// Briefing view for iPhone (stack-based navigation) and iPad detail column.
/// On iPhone, this shows a grid of cards that push to detail views.
/// On iPad in three-column mode, use `BriefingListView` for the content column instead.
struct MobileBriefingView: View {
    @EnvironmentObject private var state: MobileAppState
    @Namespace private var glassNamespace

    /// Selected project ids for filtering. Empty = show every project.
    @State private var selectedProjectIds: Set<UUID> = []

    /// When false (default), only show briefings for each project's current branch.
    @State private var showAllBranches: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        GlassEffectContainer(spacing: 16) {
                            LazyVGrid(
                                columns: gridColumns(for: proxy.size.width),
                                alignment: .leading,
                                spacing: 16
                            ) {
                                ForEach(groups) { group in
                                    NavigationLink(value: group.key) {
                                        BriefingCard(
                                            group: group,
                                            projectName: projectsById[group.projectId]?.name ?? "Unknown Project",
                                            activeJobCount: activeJobCountByProject[group.projectId] ?? 0,
                                            namespace: glassNamespace
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding(for: proxy.size.width))
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Briefing")
        .popoverTip(MobileTips.BriefingTip(), arrowEdge: .top)
        .toolbar {
            if hasAnyData {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
        }
        .refreshable {
            await state.refreshSnapshot()
        }
        .navigationDestination(for: BriefingGroupKey.self) { key in
            MobileBriefingDetailView(groupKey: key)
        }
        .navigationDestination(for: String.self) { sessionID in
            MobileChatView(sessionID: sessionID)
                .id(sessionID)
                .task(id: sessionID) {
                    if !MobileDraftSessionID.isDraft(sessionID) {
                        await state.subscribe(to: sessionID)
                    }
                }
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let minimumWidth: CGFloat
        if width >= 980 {
            minimumWidth = 360
        } else if width >= 700 {
            minimumWidth = 320
        } else {
            minimumWidth = max(280, width - (horizontalPadding(for: width) * 2))
        }

        return [
            GridItem(
                .adaptive(minimum: minimumWidth, maximum: 560),
                spacing: 16,
                alignment: .top
            )
        ]
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        if width >= 900 {
            return 24
        } else if width >= 600 {
            return 20
        } else {
            return 16
        }
    }

    private var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    /// Number of active (streaming) jobs per project. `SessionSummary` only
    /// carries `projectId`, not a branch, so the count is project-scoped and
    /// every branch card for a project shares it.
    private var activeJobCountByProject: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in state.sessions where session.isStreaming {
            counts[session.projectId, default: 0] += 1
        }
        return counts
    }

    /// Every briefing group before the project/branch filters are applied.
    private var allGroups: [GroupedBriefing] {
        groupBriefings(briefings: state.branchBriefings, threads: state.threadSummaries)
    }

    /// Briefing groups after applying the active project and branch filters.
    private var groups: [GroupedBriefing] {
        let projectFiltered: [GroupedBriefing]
        if selectedProjectIds.isEmpty {
            projectFiltered = allGroups
        } else {
            projectFiltered = allGroups.filter { selectedProjectIds.contains($0.projectId) }
        }

        if showAllBranches {
            return projectFiltered
        }
        return projectFiltered.filter { group in
            guard let branch = state.projectBranches[group.projectId] else {
                // Branch not yet mirrored from the desktop — keep the group so
                // the user isn't shown an empty state while it resolves.
                return true
            }
            return group.branch == branch
        }
    }

    /// True when at least one briefing or summary exists, regardless of filters.
    private var hasAnyData: Bool {
        !state.branchBriefings.isEmpty || !state.threadSummaries.isEmpty
    }

    /// Projects that actually have at least one briefing or summary recorded.
    private var projectsWithData: [Project] {
        let ids = Set(allGroups.map(\.projectId))
        return state.projects.filter { ids.contains($0.id) }
    }

    private var isFilterActive: Bool {
        showAllBranches || !selectedProjectIds.isEmpty
    }

    private func toggleProject(_ id: UUID) {
        if selectedProjectIds.contains(id) {
            selectedProjectIds.remove(id)
        } else {
            selectedProjectIds.insert(id)
        }
    }

    // MARK: - Filter menu

    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Section("Branches") {
                Button {
                    showAllBranches = false
                } label: {
                    menuSelectionLabel("Current branch", isSelected: !showAllBranches)
                }
                Button {
                    showAllBranches = true
                } label: {
                    menuSelectionLabel("All branches", isSelected: showAllBranches)
                }
            }

            let projects = projectsWithData
            if projects.count > 1 {
                Section("Projects") {
                    Button {
                        selectedProjectIds.removeAll()
                    } label: {
                        menuSelectionLabel("All projects", isSelected: selectedProjectIds.isEmpty)
                    }
                    ForEach(projects) { project in
                        Button {
                            toggleProject(project.id)
                        } label: {
                            menuSelectionLabel(project.name, isSelected: selectedProjectIds.contains(project.id))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: isFilterActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if hasAnyData {
            ContentUnavailableView(
                "Nothing to Show",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(
                    showAllBranches
                        ? "No briefings match the selected projects."
                        : "No briefings for the current branch. Choose All branches to see other branches."
                )
            )
        } else {
            ContentUnavailableView(
                "No Briefings Yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Briefings appear here after threads finish on your Mac.")
            )
        }
    }
}

// MARK: - Briefing List View (iPad Content Column)

/// List view for the iPad three-column layout content column.
/// Shows briefing cards in a vertical list with selection support.
struct BriefingListView: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selectedGroup: BriefingGroupKey?
    @Namespace private var glassNamespace

    /// Selected project ids for filtering. Empty = show every project.
    @State private var selectedProjectIds: Set<UUID> = []

    /// When false (default), only show briefings for each project's current branch.
    @State private var showAllBranches: Bool = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if groups.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    GlassEffectContainer(spacing: 12) {
                        ForEach(groups) { group in
                            Button {
                                selectedGroup = group.key
                            } label: {
                                BriefingListCard(
                                    group: group,
                                    projectName: projectsById[group.projectId]?.name ?? "Unknown Project",
                                    activeJobCount: activeJobCountByProject[group.projectId] ?? 0,
                                    isSelected: selectedGroup == group.key,
                                    namespace: glassNamespace
                                )
                            }
                            .buttonStyle(BriefingListCardButtonStyle(isSelected: selectedGroup == group.key))
                            .glassEffectID(group.id, in: glassNamespace)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Briefing")
        .toolbar {
            if hasAnyData {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
        }
        .refreshable {
            await state.refreshSnapshot()
        }
    }

    // MARK: - Data

    private var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    private var activeJobCountByProject: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in state.sessions where session.isStreaming {
            counts[session.projectId, default: 0] += 1
        }
        return counts
    }

    private var allGroups: [GroupedBriefing] {
        groupBriefings(briefings: state.branchBriefings, threads: state.threadSummaries)
    }

    private var groups: [GroupedBriefing] {
        let projectFiltered: [GroupedBriefing]
        if selectedProjectIds.isEmpty {
            projectFiltered = allGroups
        } else {
            projectFiltered = allGroups.filter { selectedProjectIds.contains($0.projectId) }
        }

        if showAllBranches {
            return projectFiltered
        }
        return projectFiltered.filter { group in
            guard let branch = state.projectBranches[group.projectId] else {
                return true
            }
            return group.branch == branch
        }
    }

    private var hasAnyData: Bool {
        !state.branchBriefings.isEmpty || !state.threadSummaries.isEmpty
    }

    private var projectsWithData: [Project] {
        let ids = Set(allGroups.map(\.projectId))
        return state.projects.filter { ids.contains($0.id) }
    }

    private var isFilterActive: Bool {
        showAllBranches || !selectedProjectIds.isEmpty
    }

    private func toggleProject(_ id: UUID) {
        if selectedProjectIds.contains(id) {
            selectedProjectIds.remove(id)
        } else {
            selectedProjectIds.insert(id)
        }
    }

    // MARK: - Filter Menu

    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Section("Branches") {
                Button {
                    showAllBranches = false
                } label: {
                    if !showAllBranches {
                        Label("Current branch", systemImage: "checkmark")
                    } else {
                        Text("Current branch")
                    }
                }
                Button {
                    showAllBranches = true
                } label: {
                    if showAllBranches {
                        Label("All branches", systemImage: "checkmark")
                    } else {
                        Text("All branches")
                    }
                }
            }

            let projects = projectsWithData
            if projects.count > 1 {
                Section("Projects") {
                    Button {
                        selectedProjectIds.removeAll()
                    } label: {
                        if selectedProjectIds.isEmpty {
                            Label("All projects", systemImage: "checkmark")
                        } else {
                            Text("All projects")
                        }
                    }
                    ForEach(projects) { project in
                        Button {
                            toggleProject(project.id)
                        } label: {
                            if selectedProjectIds.contains(project.id) {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: isFilterActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if hasAnyData {
            ContentUnavailableView(
                "Nothing to Show",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(
                    showAllBranches
                        ? "No briefings match the selected projects."
                        : "No briefings for the current branch."
                )
            )
        } else {
            ContentUnavailableView(
                "No Briefings Yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Briefings appear here after threads finish on your Mac.")
            )
        }
    }
}

// MARK: - Briefing List Card (Compact for Content Column)

private struct BriefingListCard: View {
    let group: GroupedBriefing
    let projectName: String
    let activeJobCount: Int
    let isSelected: Bool
    let namespace: Namespace.ID

    private var threadCount: Int { group.threads.count }

    var body: some View {
        HStack(spacing: 12) {
            // Project icon
            ZStack {
                Circle()
                    .fill(accentGradient.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accentGradient)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(group.branch)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)

                // Metadata
                FlowLayout(spacing: 8) {
                    if threadCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9, weight: .medium))
                            Text("\(threadCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    if activeJobCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text("\(activeJobCount) active")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(group.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
}

// MARK: - Briefing List Card Button Style

private struct BriefingListCardButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .glassEffect(
                glassConfig(isPressed: configuration.isPressed),
                in: .rect(cornerRadius: 14)
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

// MARK: - Briefing Card

private struct BriefingCard: View {
    let group: GroupedBriefing
    let projectName: String
    let activeJobCount: Int
    let namespace: Namespace.ID

    private var threadCount: Int { group.threads.count }
    private var hasBriefing: Bool { !(group.briefing?.briefing.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with project icon and name
            HStack(spacing: 12) {
                projectIcon
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                        Text(group.branch)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                
                Spacer(minLength: 0)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Summary content
            VStack(alignment: .leading, spacing: 12) {
                if let summary = group.briefing?.briefing, !summary.isEmpty {
                    ChatTextContentView(
                        markdown: summary,
                        size: 14,
                        color: .secondary,
                        lineSpacing: 3,
                        maximumNumberOfLines: 4
                    )
                } else {
                    Text("No summary available yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // Footer with metadata
            HStack(spacing: 12) {
                // Active jobs chip — pulses while jobs are running
                if activeJobCount > 0 {
                    ActiveJobsChip(count: activeJobCount)
                }

                // Thread count chip
                if threadCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10, weight: .medium))
                        Text("\(threadCount)")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)
                
                // Time ago
                Text(group.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .glassEffectID(group.id, in: namespace)
        .contentShape(.rect(cornerRadius: 20))
    }

    private var projectIcon: some View {
        ZStack {
            Circle()
                .fill(accentGradient.opacity(0.15))
                .frame(width: 40, height: 40)
            
            Image(systemName: "folder.fill")
                .font(.system(size: 16, weight: .medium))
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
}

// MARK: - Active Jobs Chip

/// Footer chip showing how many jobs are actively streaming for a project.
/// The dot pulses to convey live progress.
private struct ActiveJobsChip: View {
    let count: Int

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .opacity(isPulsing ? 0.35 : 1)
                .scaleEffect(isPulsing ? 0.85 : 1)
            Text("\(count) active")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityLabel("\(count) active jobs")
    }
}

func groupBriefings(
    briefings: [MobileBranchBriefing],
    threads: [MobileThreadSummary]
) -> [GroupedBriefing] {
    var buckets: [String: GroupedBriefing] = [:]

    for briefing in briefings {
        let key = "\(briefing.projectId.uuidString)::\(briefing.branch)"
        buckets[key] = GroupedBriefing(
            projectId: briefing.projectId,
            branch: briefing.branch,
            briefing: briefing,
            threads: buckets[key]?.threads ?? [],
            updatedAt: max(briefing.updatedAt, buckets[key]?.updatedAt ?? .distantPast)
        )
    }

    for thread in threads {
        let key = "\(thread.projectId.uuidString)::\(thread.branch)"
        let existing = buckets[key]
        var existingThreads = existing?.threads ?? []
        existingThreads.append(thread)
        buckets[key] = GroupedBriefing(
            projectId: thread.projectId,
            branch: thread.branch,
            briefing: existing?.briefing,
            threads: existingThreads.sorted { $0.updatedAt > $1.updatedAt },
            updatedAt: max(thread.updatedAt, existing?.updatedAt ?? .distantPast)
        )
    }

    return buckets.values.sorted { $0.updatedAt > $1.updatedAt }
}
