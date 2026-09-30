import SwiftUI
import Foundation
import RxCodeCore
import RxCodeChatKit

struct BriefingView: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState

    /// Selected project ids for filtering. Empty = show every project.
    @State var selectedProjectIds: Set<UUID> = []

    /// Cached current branch per project path, refreshed when the project list
    /// changes. Only drives the CI / PR chips; the timeline shows every branch.
    @State var currentBranchByProject: [UUID: String] = [:]

    /// Group id whose copy button most recently fired; used for transient checkmark feedback.
    @State var recentlyCopiedGroupId: String?

    @State var presentedBriefing: BriefingGroup?
    @State var briefingToDelete: BriefingGroup?
    @State var presentedDocument: BriefingDocument?
    @State var documentToDelete: BriefingDocument?

    /// Which kinds of briefing the tab shows.
    @State var kindFilter: KindFilter = .all

    /// Time window the timeline is limited to, matched against each
    /// briefing's creation time.
    @State var timeFilter: BriefingTimeFilter = .all

    /// Presents the custom date range picker for `timeFilter`.
    @State var showCustomRangeSheet = false

    enum KindFilter: CaseIterable {
        case all, project, document

        var title: LocalizedStringKey {
            switch self {
            case .all: "All briefings"
            case .project: "Project summaries"
            case .document: "Documents"
            }
        }

        var icon: String {
            switch self {
            case .all: "square.stack"
            case .project: "arrow.triangle.branch"
            case .document: "doc.richtext"
            }
        }
    }

    static let maximumSummaryPreviewHeight: CGFloat = 220
    private static let visibleThreadCount = 3

    /// Timeline width reported by the table view; drives the grid column count.
    @State var availableWidth: CGFloat = 800

    /// Presents the account-level autopilot automation settings form.
    @State private var showAutomationSettings = false

    /// Presents the account-level repo-setup template manager.
    @State private var showRepoSetup = false

    /// Live scroll metrics and day markers feeding the timeline scrubber. Held
    /// in an observable box that only the scrubber reads, so scrolling doesn't
    /// re-evaluate this view's body (and rebuild every card) each frame.
    @State private var scrollMetrics = BriefingTimelineScrollMetrics()

    /// The work done on one project branch during a single calendar day. A
    /// branch worked on across several days yields one group per day; each
    /// chat belongs to the day it was created.
    struct BriefingGroup: Identifiable {
        let projectId: UUID
        let branch: String
        /// Start of the calendar day this group covers.
        let day: Date
        let briefing: BranchBriefingItem?
        let threadSummaries: [ThreadSummaryItem]
        let updatedAt: Date
        /// Earliest activity recorded for this day — the day briefing's
        /// creation or the first chat started — used for timeline order.
        let createdAt: Date
        var id: String { BranchBriefingRecord.makeId(projectId: projectId, branch: branch, day: day) }
    }

    /// One card on the timeline: either a project (branch) summary or a
    /// published agent-written document briefing.
    enum BriefingEntry: Identifiable {
        case project(BriefingGroup)
        case document(BriefingDocument)

        var id: String {
            switch self {
            case .project(let group): "project::\(group.id)"
            case .document(let document): "document::\(document.id.uuidString)"
            }
        }

        var projectId: UUID? {
            switch self {
            case .project(let group): group.projectId
            case .document(let document): document.projectId
            }
        }

        /// Timeline position: when the briefing first appeared.
        var createdAt: Date {
            switch self {
            case .project(let group): group.createdAt
            case .document(let document): document.publishedAt ?? document.createdAt
            }
        }

        var updatedAt: Date {
            switch self {
            case .project(let group): group.updatedAt
            case .document(let document): document.updatedAt
            }
        }
    }

    /// Briefings created on the same calendar day, shown under one date header.
    struct BriefingDaySection: Identifiable {
        let day: Date
        let entries: [BriefingEntry]
        var id: String { "day::\(day.timeIntervalSinceReferenceDate)" }
    }

    var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0) })
    }

    private var focusedProject: Project? {
        if let selectedId = windowState.selectedProject?.id,
           let selected = projectsById[selectedId] {
            return selected
        }
        if let activePath = appState.activeProjectPath,
           let active = appState.projects.first(where: { $0.path == activePath }) {
            return active
        }
        return appState.projects.count == 1 ? appState.projects.first : nil
    }

    private var knownProjectIds: Set<UUID> {
        Set(appState.projects.map(\.id))
    }

    /// Thread summaries for known projects, excluding `[Code Review]` threads.
    /// Review threads are kept out of briefings at write time; this also filters
    /// any summaries persisted before that exclusion existed.
    private func visibleThreadSummaryItems() -> [ThreadSummaryItem] {
        let knownIds = knownProjectIds
        let reviewIds = appState.codeReviewThreadIds
        return appState.threadStore.allThreadSummaryItems()
            .filter { knownIds.contains($0.projectId) && !reviewIds.contains($0.sessionId) }
    }

    private var allGroups: [BriefingGroup] {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision

        let knownIds = knownProjectIds
        return Self.dayGroups(
            briefings: appState.threadStore.allBranchBriefingItems().filter { knownIds.contains($0.projectId) },
            threads: visibleThreadSummaryItems()
        )
    }

    /// Buckets briefings and chat summaries by project, branch and calendar
    /// day. Chats go to the day they were created; day briefings to their own
    /// day. A legacy whole-branch briefing (no day) is shown on the day it
    /// was last updated unless that day already has its own briefing.
    static func dayGroups(
        briefings: [BranchBriefingItem],
        threads: [ThreadSummaryItem],
        calendar: Calendar = .current
    ) -> [BriefingGroup] {
        struct Bucket {
            var projectId: UUID
            var branch: String
            var day: Date
            var briefing: BranchBriefingItem?
            var threads: [ThreadSummaryItem] = []
            var updated: Date = .distantPast
            var created: Date = .distantFuture
        }

        var buckets: [String: Bucket] = [:]
        func add(projectId: UUID, branch: String, day: Date, _ update: (inout Bucket) -> Void) {
            let key = BranchBriefingRecord.makeId(projectId: projectId, branch: branch, day: day)
            var bucket = buckets[key] ?? Bucket(projectId: projectId, branch: branch, day: day)
            update(&bucket)
            buckets[key] = bucket
        }

        // Dated briefings first so a legacy briefing never displaces one.
        let ordered = briefings.filter { $0.day != nil } + briefings.filter { $0.day == nil }
        for item in ordered {
            let day = calendar.startOfDay(for: item.day ?? item.updatedAt)
            add(projectId: item.projectId, branch: item.branch, day: day) { bucket in
                guard bucket.briefing == nil else { return }
                bucket.briefing = item
                bucket.updated = max(bucket.updated, item.updatedAt)
                if calendar.isDate(item.createdAt, inSameDayAs: day) {
                    bucket.created = min(bucket.created, item.createdAt)
                }
            }
        }
        for thread in threads {
            let day = calendar.startOfDay(for: thread.createdAt)
            add(projectId: thread.projectId, branch: thread.branch, day: day) { bucket in
                bucket.threads.append(thread)
                bucket.updated = max(bucket.updated, thread.updatedAt)
                bucket.created = min(bucket.created, thread.createdAt)
            }
        }

        return buckets.values.map {
            BriefingGroup(
                projectId: $0.projectId,
                branch: $0.branch,
                day: $0.day,
                briefing: $0.briefing,
                threadSummaries: $0.threads.sorted { $0.updatedAt > $1.updatedAt },
                updatedAt: $0.updated == .distantPast ? $0.day : $0.updated,
                createdAt: $0.created == .distantFuture ? $0.day : $0.created
            )
        }
    }

    private var groups: [BriefingGroup] {
        guard !selectedProjectIds.isEmpty else { return allGroups }
        return allGroups.filter { selectedProjectIds.contains($0.projectId) }
    }

    /// Published document briefings matching the project filter. Documents
    /// without a project are only shown when no project filter is active.
    private var visibleDocuments: [BriefingDocument] {
        appState.briefingDocuments.filter { document in
            guard document.isPublished else { return false }
            guard !selectedProjectIds.isEmpty else { return true }
            return document.projectId.map(selectedProjectIds.contains) ?? false
        }
    }

    /// Project summaries and document briefings merged into one timeline,
    /// newest first. Ties follow the sidebar project order, then recency.
    private var entries: [BriefingEntry] {
        var result: [BriefingEntry] = []
        if kindFilter != .document {
            result += groups.map(BriefingEntry.project)
        }
        if kindFilter != .project {
            result += visibleDocuments.map(BriefingEntry.document)
        }
        if let interval = timeFilter.interval() {
            result = result.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end }
        }
        let projectOrder: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: appState.projects.enumerated().map { ($0.element.id, $0.offset) }
        )
        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            let lhsOrder = lhs.projectId.flatMap { projectOrder[$0] } ?? Int.max
            let rhsOrder = rhs.projectId.flatMap { projectOrder[$0] } ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Projects that actually have at least one briefing or summary recorded.
    var projectsWithData: [Project] {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision
        let knownIds = knownProjectIds
        let ids = Set(
            appState.threadStore.allBranchBriefingItems()
                .filter { knownIds.contains($0.projectId) }
                .map(\.projectId)
            + visibleThreadSummaryItems().map(\.projectId)
            + appState.briefingDocuments.filter(\.isPublished).compactMap(\.projectId)
        )
        return appState.projects.filter { ids.contains($0.id) }
    }

    var body: some View {
        Group {
            if hasAnyData {
                content
            } else {
                emptyState(
                    icon: "text.page",
                    title: "No Briefings Yet",
                    message: "Briefings appear after a thread finishes on a project branch, or when an agent publishes one."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ClaudeTheme.background)
        .task(id: projectPathsKey) {
            await refreshCurrentBranches()
            await appState.refreshProjectGitDirty()
        }
        .task {
            await appState.reloadBriefingDocuments()
        }
        .onAppear {
            AnalyticsService.shared.log(.briefingListOpened)
        }
        .sheet(isPresented: $showAutomationSettings) {
            AutomationSettingsSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showRepoSetup) {
            RepoSetupManageSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showCustomRangeSheet) {
            customRangeSheet
        }
        .sheet(item: $presentedBriefing) { group in
            briefingSheet(group)
        }
        .sheet(item: $presentedDocument) { document in
            BriefingDocumentSheet(
                document: document,
                project: document.projectId.flatMap { projectsById[$0] }
            )
            .environment(appState)
        }
        .sheet(item: $documentToDelete) { document in
            DeleteBriefingSheet(
                message: "Delete \"\(document.title)\"? Its content and all of its images, videos, and files will be removed."
            ) {
                try await appState.deleteBriefingDocument(document)
            }
        }
        .sheet(item: $briefingToDelete) { group in
            DeleteBriefingSheet(
                message: "Delete the generated briefing for \(projectsById[group.projectId]?.name ?? "Unknown project") on \(group.branch) from \(group.day.formatted(date: .abbreviated, time: .omitted))? Thread summaries will remain available."
            ) {
                if let briefing = group.briefing {
                    _ = try appState.deleteBranchBriefing(briefing)
                }
            }
        }
    }

    /// True when there is at least one briefing or thread summary persisted, regardless
    /// of the active filters. Used to decide whether the filter bar should be shown.
    private var hasAnyData: Bool {
        _ = appState.branchBriefingRevision
        _ = appState.threadSummaryRevision
        let knownIds = knownProjectIds
        return appState.briefingDocuments.contains(where: \.isPublished)
            || appState.threadStore.allBranchBriefingItems().contains { knownIds.contains($0.projectId) }
            || !visibleThreadSummaryItems().isEmpty
    }

    private var projectPathsKey: String {
        appState.projects
            .map { "\($0.id.uuidString):\($0.path)" }
            .joined(separator: "|")
    }

    private func refreshCurrentBranches() async {
        currentBranchByProject = [:]
        let selectedId = focusedProject?.id
        let orderedProjects = appState.projects.filter { $0.id == selectedId }
            + appState.projects.filter { $0.id != selectedId }
        for project in orderedProjects {
            if let branch = await GitHelper.currentBranch(at: project.path) {
                guard !Task.isCancelled else { return }
                currentBranchByProject[project.id] = branch
            }
            guard !Task.isCancelled else { return }
        }
    }

    private var content: some View {
        let entries = self.entries
        let sections = daySections(entries)
        let showsScrubber = sections.count > 1
        return HStack(spacing: 0) {
            BriefingTimelineTableView(
                rows: timelineRows(entries: entries, sections: sections),
                anchors: sections.map {
                    BriefingTimelineSectionAnchor(id: $0.id, date: $0.day, rowId: Self.sectionTitleRowId($0))
                },
                metrics: scrollMetrics,
                showsScroller: !showsScrubber
            ) { width in
                availableWidth = width
            }

            if showsScrubber {
                BriefingTimelineScrubber(metrics: scrollMetrics)
                    .padding(.trailing, 8)
            }
        }
    }

    /// Header, empty state, and the day sections, as full-width rows
    /// of the AppKit timeline.
    private func timelineRows(entries: [BriefingEntry], sections: [BriefingDaySection]) -> [BriefingTimelineRow] {
        var rows = [
            BriefingTimelineRow(id: "header", estimatedHeight: 300) {
                AnyView(
                    VStack(alignment: .leading, spacing: 24) {
                        hero(entries: entries)
                        filterBar
                        BriefingUsageStatsView(projectIds: selectedProjectIds)
                    }
                    .padding(.top, 24)
                    .briefingTimelineRowInsets()
                )
            }
        ]
        if sections.isEmpty {
            rows.append(BriefingTimelineRow(id: "empty", estimatedHeight: 260) {
                AnyView(filteredEmptyState.briefingTimelineRowInsets())
            })
        } else {
            rows += sections.flatMap(sectionRows)
        }
        rows.append(BriefingTimelineRow(id: "footer", estimatedHeight: 40) {
            AnyView(Color.clear.frame(height: 40))
        })
        return rows
    }

    // MARK: - Hero

    private func hero(entries: [BriefingEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.14))
                    Image(systemName: "text.page")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Briefings")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text(heroSubtitle(entries))
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer(minLength: 0)

                if appState.isSignedIn {
                    autopilotMenu
                }
            }
        }
    }

    /// Account-level autopilot entry points. Automation settings and repo-setup
    /// templates are user-scoped (not per-project), so they live in the briefing
    /// hero rather than on individual cards — mirroring the Autopilot settings tab.
    private var autopilotMenu: some View {
        Menu {
            Button {
                showAutomationSettings = true
            } label: {
                Label("Automation Settings", systemImage: "wand.and.stars")
            }
            Button {
                showRepoSetup = true
            } label: {
                Label("Repo Setup Templates", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                Text("Autopilot")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Manage autopilot automation settings and repo-setup templates.")
    }

    private func heroSubtitle(_ entries: [BriefingEntry]) -> String {
        let count = entries.count
        let briefings = count == 1 ? "briefing" : "briefings"
        let projectCount = Set(entries.compactMap(\.projectId)).count
        let projects = projectCount == 1 ? "project" : "projects"
        let selected = selectedProjectIds.isEmpty ? "" : "selected "
        let period = timeFilter == .all ? "" : " · \(timeFilter.title)"
        return "\(count) \(briefings) across \(projectCount) \(selected)\(projects)\(period)."
    }

    // MARK: - Group card

    func groupCard(_ group: BriefingGroup) -> some View {
        let project = projectsById[group.projectId]
        return VStack(alignment: .leading, spacing: 12) {
            groupCardHeader(group, project: project)

            if let briefing = group.briefing {
                Divider().opacity(0.4)
                BriefingSummaryPreview(
                    text: briefing.briefing,
                    maximumHeight: Self.maximumSummaryPreviewHeight
                ) {
                    presentedBriefing = group
                }
            }

            if !group.threadSummaries.isEmpty {
                Divider().opacity(0.4)
                threadList(Array(group.threadSummaries.prefix(Self.visibleThreadCount)), totalCount: group.threadSummaries.count)
            }

            if group.threadSummaries.count > Self.visibleThreadCount {
                BriefingShowMoreButton {
                    presentedBriefing = group
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
    }

    private func briefingSheet(_ group: BriefingGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupCardHeader(group, project: projectsById[group.projectId])
                .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let briefing = group.briefing {
                        MarkdownContentView(text: GeneratedTextSanitizer.cleanMarkdownDocument(briefing.briefing))
                    }
                    if !group.threadSummaries.isEmpty {
                        if group.briefing != nil {
                            Divider()
                        }
                        threadList(group.threadSummaries, totalCount: group.threadSummaries.count)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { presentedBriefing = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 420, idealHeight: 660)
        .background(ClaudeTheme.background)
    }

    private func groupCardHeader(_ group: BriefingGroup, project: Project?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? "Unknown project")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Created \(Self.creationTime(group.createdAt)) · Updated \(Self.compactDate(group.updatedAt))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .help("Created \(group.createdAt.formatted(date: .complete, time: .shortened))")
                }

                Spacer(minLength: 0)

                copyButton(for: group)

                if let project {
                    cardMenu(for: group, project: project)
                }
            }

            // Status chips wrap onto multiple lines so a narrow card never
            // truncates the branch / CI / release / PR indicators.
            FlowLayout(spacing: 6, lineSpacing: 6) {
                BriefingInfoChip(icon: "arrow.triangle.branch", text: group.branch, accented: true)
                ciChip(for: group)
                if let project, let version = appState.projectLatestReleaseVersion(project) {
                    BriefingInfoChip(icon: "tag.fill", text: version)
                }
                BriefingPRStatusView(
                    projectId: group.projectId,
                    branch: group.branch,
                    project: project
                )
            }
        }
    }


    // MARK: - Thread list (compact rows)

    private func threadList(_ items: [ThreadSummaryItem], totalCount: Int) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Threads")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("\(totalCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ClaudeTheme.surfaceSecondary))
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
                threadRow(item)
            }
        }
    }

    private func threadRow(_ item: ThreadSummaryItem) -> some View {
        BriefingThreadRow(
            item: item,
            isInProgress: appState.sessionActivity[item.sessionId]?.isStreaming == true,
            todoProgress: appState.todoProgress(forSessionId: item.sessionId),
            reviewPassed: appState.reviewPassedBySession[item.sessionId]
        ) {
            presentedBriefing = nil
            appState.selectSession(id: item.sessionId, in: windowState)
        }
    }

    // MARK: - Empty State

    func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.surfaceSecondary)
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 60)
    }

    /// Time of day for briefings created today (the day header carries the
    /// date), otherwise an abbreviated date and time.
    private static func creationTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func compactDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// `BriefingThreadRow` / `BriefingThreadProgressBadge` live in `BriefingThreadRow.swift`.
// `BriefingMarkdownView` lives in `BriefingMarkdownView.swift`.
