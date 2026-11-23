import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import TipKit

/// Briefing timeline for iPhone (stack-based navigation) and the iPad detail
/// column: usage cards, then briefings grouped by day on a vertical timeline,
/// like the desktop Briefing tab. Cards push to detail views.
/// On iPad in three-column mode, `BriefingListView` is the content column.
struct MobileBriefingView: View {
    @EnvironmentObject private var state: MobileAppState
    var onCloseChat: () -> Void = {}
    var onOpenSession: (String) -> Void = { _ in }

    @State private var filters = MobileBriefingFilters()

    private var visibleUsageCards: [UsageCardConfiguration] {
        state.usageDashboard.visibleCards(projectIDs: filters.projectIds)
    }

    var body: some View {
        let sections = state.briefingSections(filters: filters)
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !visibleUsageCards.isEmpty {
                            UsageCardGridLayout(minimumColumnWidth: 150, rowHeight: 170, spacing: 16) {
                                ForEach(visibleUsageCards) { card in
                                    if let snapshot = state.usageDashboard.snapshot(for: card) {
                                        UsagePluginCard(snapshot: snapshot, configuration: card)
                                            .usageCardSize(card.cardSize)
                                    }
                                }
                            }
                        }
                        if sections.isEmpty {
                            emptyState
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: max(0, proxy.size.height - (visibleUsageCards.isEmpty ? 40 : 240)),
                                    maxHeight: .infinity
                                )
                        } else {
                            MobileBriefingTimeline(
                                sections: sections,
                                columnCount: columnCount(for: proxy.size.width)
                            ) { entry in
                                card(for: entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, horizontalPadding(for: proxy.size.width))
                    .padding(.trailing, horizontalPadding(for: proxy.size.width) + (showsScrubber(sections) ? 12 : 0))
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
                .overlay(alignment: .trailing) {
                    if showsScrubber(sections) {
                        MobileBriefingTimelineScrubber(sections: sections) { section in
                            scrollProxy.scrollTo(section.id, anchor: .top)
                        }
                        .padding(.vertical, 24)
                    }
                }
            }
        }
        .background(MobileCard.pageBackground)
        .navigationTitle("Briefing")
        .navigationSubtitle(subtitle(sections))
        .popoverTip(MobileTips.BriefingTip(), arrowEdge: .top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                MobileConnectionPathBadge()
            }
            if hasAnyData {
                ToolbarItem(placement: .topBarTrailing) {
                    MobileBriefingFilterMenu(filters: $filters, projects: projectsWithData)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: filters)
        .refreshable {
            await state.refreshSnapshot()
        }
        .onAppear {
            AnalyticsService.shared.log(.briefingListOpened)
        }
        .navigationDestination(for: BriefingGroupKey.self) { key in
            MobileBriefingDetailView(groupKey: key, onOpenSession: onOpenSession)
        }
        .navigationDestination(for: UUID.self) { id in
            if let document = state.briefingDocuments.first(where: { $0.id == id }) {
                MobileDocumentBriefingDetailView(document: document)
            }
        }
        .navigationDestination(for: String.self) { sessionID in
            MobileChatView(sessionID: sessionID, onClose: onCloseChat)
                .id(sessionID)
                .toolbar(.hidden, for: .tabBar)
                .task(id: sessionID) {
                    if !MobileDraftSessionID.isDraft(sessionID) {
                        await state.subscribe(to: sessionID)
                    }
                }
        }
    }

    @ViewBuilder
    private func card(for entry: MobileBriefingEntry) -> some View {
        switch entry {
        case .project(let group):
            NavigationLink(value: group.key) {
                BriefingCard(
                    group: group,
                    projectName: projectsById[group.projectId]?.name ?? "Unknown Project",
                    activeJobCount: activeJobCountByProject[group.projectId] ?? 0,
                    ciStatus: ciStatus(for: group)
                )
                .equatable()
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { MobileHaptics.buttonTap() })
            .accessibilityIdentifier("briefing-card-\(group.id)")
            .projectRemoteContextMenu(project: projectsById[group.projectId], branch: group.branch)
        case .document(let document):
            NavigationLink(value: document.id) {
                MobileDocumentBriefingCard(
                    document: document,
                    projectName: document.projectId.flatMap { projectsById[$0]?.name }
                )
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { MobileHaptics.buttonTap() })
            .accessibilityIdentifier("briefing-document-card-\(document.id.uuidString)")
        }
    }

    private func showsScrubber(_ sections: [MobileBriefingDaySection]) -> Bool {
        sections.count > 3
    }

    private func subtitle(_ sections: [MobileBriefingDaySection]) -> Text {
        let count = sections.reduce(0) { $0 + $1.entries.count }
        guard count > 0 else { return Text(verbatim: "") }
        let briefings = count == 1 ? String(localized: "1 briefing") : String(localized: "\(count) briefings")
        let days = sections.count == 1 ? String(localized: "1 day") : String(localized: "\(sections.count) days")
        return Text(verbatim: "\(briefings) · \(days)")
    }

    /// Cards per timeline row: one on iPhone, more on wide iPad layouts.
    private func columnCount(for width: CGFloat) -> Int {
        let available = width - horizontalPadding(for: width) * 2 - 24
        return max(1, min(3, Int(available / 340)))
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

    /// True when at least one briefing or summary exists, regardless of filters.
    private var hasAnyData: Bool {
        !state.branchBriefings.isEmpty || !state.threadSummaries.isEmpty || !state.briefingPlans.isEmpty || !state.briefingDocuments.isEmpty
            || !state.usageDashboard.visibleCards().isEmpty
    }

    /// Projects that actually have at least one briefing or summary recorded.
    private var projectsWithData: [Project] {
        let ids = Set(state.briefingGroups.map(\.projectId) + state.briefingDocuments.compactMap(\.projectId)
            + state.usageDashboard.snapshots.compactMap(\.projectID))
        return state.projects.filter { ids.contains($0.id) }
    }

    private func ciStatus(for group: GroupedBriefing) -> ProjectCIStatus? {
        guard state.projectBranches[group.projectId] == group.branch else { return nil }
        return state.ciStatusByProject[group.projectId]
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if hasAnyData {
            ContentUnavailableView {
                Label("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No briefings match the selected filters.")
            } actions: {
                Button("Reset Filters") {
                    MobileHaptics.buttonTap()
                    filters = MobileBriefingFilters()
                }
            }
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

/// Timeline list for the iPad three-column layout content column, with
/// selection support. Uses the same day sections and filters as
/// `MobileBriefingView`.
struct BriefingListView: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selectedGroup: BriefingGroupKey?
    @State private var selectedDocument: MobileBriefingDocument?
    @State private var filters = MobileBriefingFilters()

    var body: some View {
        let sections = state.briefingSections(filters: filters)
        ScrollViewReader { scrollProxy in
            ScrollView {
                if sections.isEmpty {
                    emptyState
                        .containerRelativeFrame([.horizontal, .vertical])
                } else {
                    MobileBriefingTimeline(sections: sections) { entry in
                        card(for: entry)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, sections.count > 3 ? 28 : 16)
                    .padding(.vertical, 12)
                }
            }
            .overlay(alignment: .trailing) {
                if sections.count > 3 {
                    MobileBriefingTimelineScrubber(sections: sections) { section in
                        scrollProxy.scrollTo(section.id, anchor: .top)
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(MobileCard.pageBackground)
        .accessibilityIdentifier("briefing-list-screen")
        .navigationTitle("Briefing")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                MobileConnectionPathBadge()
            }
            if hasAnyData {
                ToolbarItem(placement: .topBarTrailing) {
                    MobileBriefingFilterMenu(filters: $filters, projects: projectsWithData)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: filters)
        .refreshable {
            await state.refreshSnapshot()
        }
        .sheet(item: $selectedDocument) { document in
            NavigationStack {
                MobileDocumentBriefingDetailView(document: document)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                MobileHaptics.buttonTap()
                                selectedDocument = nil
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func card(for entry: MobileBriefingEntry) -> some View {
        switch entry {
        case .project(let group):
            Button {
                MobileHaptics.buttonTap()
                selectedGroup = group.key
            } label: {
                BriefingListCard(
                    group: group,
                    projectName: projectsById[group.projectId]?.name ?? "Unknown Project",
                    activeJobCount: activeJobCountByProject[group.projectId] ?? 0,
                    ciStatus: ciStatus(for: group),
                    isSelected: selectedGroup == group.key
                )
            }
            .buttonStyle(BriefingListCardButtonStyle(isSelected: selectedGroup == group.key))
            .accessibilityIdentifier("briefing-list-card-\(group.id)")
            .projectRemoteContextMenu(project: projectsById[group.projectId], branch: group.branch)
        case .document(let document):
            Button {
                MobileHaptics.buttonTap()
                selectedDocument = document
            } label: {
                MobileDocumentBriefingCard(
                    document: document,
                    projectName: document.projectId.flatMap { projectsById[$0]?.name }
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("briefing-document-card-\(document.id.uuidString)")
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

    private var hasAnyData: Bool {
        !state.branchBriefings.isEmpty || !state.threadSummaries.isEmpty || !state.briefingPlans.isEmpty || !state.briefingDocuments.isEmpty
    }

    private var projectsWithData: [Project] {
        let ids = Set(state.briefingGroups.map(\.projectId) + state.briefingDocuments.compactMap(\.projectId))
        return state.projects.filter { ids.contains($0.id) }
    }

    private func ciStatus(for group: GroupedBriefing) -> ProjectCIStatus? {
        guard state.projectBranches[group.projectId] == group.branch else { return nil }
        return state.ciStatusByProject[group.projectId]
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if hasAnyData {
            ContentUnavailableView {
                Label("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No briefings match the selected filters.")
            } actions: {
                Button("Reset Filters") {
                    MobileHaptics.buttonTap()
                    filters = MobileBriefingFilters()
                }
            }
        } else {
            ContentUnavailableView(
                "No Briefings Yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Briefings appear here after threads finish on your Mac.")
            )
        }
    }
}

// MARK: - Briefing Card

private struct BriefingCard: View, Equatable {
    let group: GroupedBriefing
    let projectName: String
    let activeJobCount: Int
    let ciStatus: ProjectCIStatus?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectName == rhs.projectName
            && lhs.activeJobCount == rhs.activeJobCount
            && lhs.ciStatus == rhs.ciStatus
            && lhs.group.key == rhs.group.key
            && lhs.group.updatedAt == rhs.group.updatedAt
            && lhs.group.plans == rhs.group.plans
            && lhs.group.briefing?.briefing == rhs.group.briefing?.briefing
            && lhs.threadCount == rhs.threadCount
    }

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
                        Image(systemName: group.branch.lowercased() == "unknown" ? "plus.circle" : "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                        Text(group.branch.lowercased() == "unknown" ? "Initialize Git" : group.branch)
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
                    // Bound preview parsing; the detail screen renders the
                    // complete document using the same Markdown view.
                    MarkdownContentView(text: String(summary.prefix(600)))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, maxHeight: 88, alignment: .topLeading)
                        .clipped()
                } else if let plan = group.plans.first {
                    Label(plan.title, systemImage: "list.bullet.clipboard")
                        .font(.subheadline)
                        .lineLimit(2)
                } else {
                    Text("No summary available yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // Footer with metadata. Chips wrap onto extra rows instead of
            // squeezing (which split "1 active" and truncated the CI label);
            // the time stays pinned to the trailing edge of the last row.
            HStack(alignment: .bottom, spacing: 12) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    // Active jobs chip — pulses while jobs are running
                    if activeJobCount > 0 {
                        ActiveJobsChip(count: activeJobCount)
                            .fixedSize()
                    }

                    if let ciStatus {
                        MobileCIStatusChip(status: ciStatus)
                            .fixedSize()
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
                        .mobileCardChipBackground()
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Time ago
                Text(group.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
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
            Text("\(count) active", tableName: "Localizable")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .mobileCardChipBackground()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityLabel(Text("\(count) active jobs", tableName: "Localizable"))
    }
}
