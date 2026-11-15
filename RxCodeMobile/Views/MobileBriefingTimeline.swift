import SwiftUI
import RxCodeCore
import RxCodeSync
import UIKit

// MARK: - Grouping

/// Identifies one project-summary card: the work on a project branch during
/// one calendar day. `day` is nil only for keys built by older call sites that
/// address a whole branch.
struct BriefingGroupKey: Hashable {
    let projectId: UUID
    let branch: String
    var day: Date?
}

/// The work done on one project branch during a single calendar day — the
/// mobile mirror of the desktop `BriefingView.BriefingGroup`.
struct GroupedBriefing: Identifiable {
    let projectId: UUID
    let branch: String
    /// Start of the calendar day this group covers.
    let day: Date
    let briefing: MobileBranchBriefing?
    let threads: [MobileThreadSummary]
    let updatedAt: Date
    /// Earliest activity recorded for the day; drives timeline order.
    let createdAt: Date

    var id: String { "\(projectId.uuidString)::\(branch)::\(day.timeIntervalSinceReferenceDate)" }
    var key: BriefingGroupKey { BriefingGroupKey(projectId: projectId, branch: branch, day: day) }
}

/// Buckets briefings and chat summaries by project, branch and calendar day,
/// matching the desktop timeline. Chats go to the day they were created; day
/// briefings to their own day. A legacy whole-branch briefing (no day, sent by
/// older desktops) is shown on the day it was last updated unless that day
/// already has its own briefing. Result is ordered most recently updated first.
func groupBriefings(
    briefings: [MobileBranchBriefing],
    threads: [MobileThreadSummary],
    calendar: Calendar = .current
) -> [GroupedBriefing] {
    struct Bucket {
        var projectId: UUID
        var branch: String
        var day: Date
        var briefing: MobileBranchBriefing?
        var threads: [MobileThreadSummary] = []
        var updated: Date = .distantPast
        var created: Date = .distantFuture
    }

    var buckets: [BriefingGroupKey: Bucket] = [:]
    func add(projectId: UUID, branch: String, day: Date, _ update: (inout Bucket) -> Void) {
        let key = BriefingGroupKey(projectId: projectId, branch: branch, day: day)
        var bucket = buckets[key] ?? Bucket(projectId: projectId, branch: branch, day: day)
        update(&bucket)
        buckets[key] = bucket
    }

    // Dated briefings first so a legacy briefing never displaces one; among
    // legacy briefings the newest wins its day.
    let ordered = briefings.filter { $0.day != nil }
        + briefings.filter { $0.day == nil }.sorted { $0.updatedAt > $1.updatedAt }
    for item in ordered {
        let day = calendar.startOfDay(for: item.day ?? item.updatedAt)
        add(projectId: item.projectId, branch: item.branch, day: day) { bucket in
            guard bucket.briefing == nil else { return }
            bucket.briefing = item
            bucket.updated = max(bucket.updated, item.updatedAt)
            let created = item.createdAt ?? item.updatedAt
            if calendar.isDate(created, inSameDayAs: day) {
                bucket.created = min(bucket.created, created)
            }
        }
    }
    // Mutate each bucket in place, then sort its threads once.
    for thread in threads {
        let created = thread.createdAt ?? thread.updatedAt
        add(projectId: thread.projectId, branch: thread.branch, day: calendar.startOfDay(for: created)) { bucket in
            bucket.threads.append(thread)
            bucket.updated = max(bucket.updated, thread.updatedAt)
            bucket.created = min(bucket.created, created)
        }
    }

    return buckets.values.map {
        GroupedBriefing(
            projectId: $0.projectId,
            branch: $0.branch,
            day: $0.day,
            briefing: $0.briefing,
            threads: $0.threads.sorted { $0.updatedAt > $1.updatedAt },
            updatedAt: $0.updated == .distantPast ? $0.day : $0.updated,
            createdAt: $0.created == .distantFuture ? $0.day : $0.created
        )
    }.sorted { $0.updatedAt > $1.updatedAt }
}

extension Array where Element == GroupedBriefing {
    /// Reorder briefing groups to follow the given project order. Groups whose
    /// project isn't in the list sort last; within the same project the most
    /// recently updated comes first.
    func sortedByProjectOrder(_ projects: [Project]) -> [GroupedBriefing] {
        let order: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) }
        )
        return sorted { lhs, rhs in
            let lhsOrder = order[lhs.projectId] ?? Int.max
            let rhsOrder = order[rhs.projectId] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

// MARK: - Timeline model

/// One card on the briefing timeline.
enum MobileBriefingEntry: Identifiable {
    case project(GroupedBriefing)
    case document(MobileBriefingDocument)

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
        case .document(let document): document.createdAt
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
struct MobileBriefingDaySection: Identifiable {
    let day: Date
    let entries: [MobileBriefingEntry]
    var id: String { "day::\(day.timeIntervalSinceReferenceDate)" }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

/// Filters for the briefing timeline, mirroring the desktop filter bar.
struct MobileBriefingFilters: Equatable {
    enum Kind: CaseIterable {
        case all, project, document

        var title: LocalizedStringKey {
            switch self {
            case .all: "All briefings"
            case .project: "Project summaries"
            case .document: "Documents"
            }
        }
    }

    enum TimeRange: CaseIterable {
        case all, today, week, month

        var title: LocalizedStringKey {
            switch self {
            case .all: "All time"
            case .today: "Today"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            }
        }

        func startDate(now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .all: nil
            case .today: calendar.startOfDay(for: now)
            case .week: calendar.date(byAdding: .day, value: -7, to: now)
            case .month: calendar.date(byAdding: .day, value: -30, to: now)
            }
        }
    }

    var kind: Kind = .all
    var timeRange: TimeRange = .all
    /// The desktop timeline shows every branch; "Current branch" narrows
    /// project summaries to each project's checked-out branch.
    var currentBranchOnly = false
    /// Empty = every project.
    var projectIds: Set<UUID> = []

    var isActive: Bool {
        kind != .all || timeRange != .all || currentBranchOnly || !projectIds.isEmpty
    }

    /// Project summaries and documents merged into one timeline, newest first.
    /// Ties follow the sidebar project order, then recency.
    func entries(
        groups: [GroupedBriefing],
        documents: [MobileBriefingDocument],
        currentBranches: [UUID: String],
        projects: [Project],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MobileBriefingEntry] {
        var result: [MobileBriefingEntry] = []
        if kind != .document {
            result += groups.lazy
                .filter { projectIds.isEmpty || projectIds.contains($0.projectId) }
                .filter { group in
                    // A branch not yet mirrored from the desktop stays visible.
                    guard currentBranchOnly, let branch = currentBranches[group.projectId] else { return true }
                    return group.branch == branch
                }
                .map(MobileBriefingEntry.project)
        }
        if kind != .project {
            result += documents.lazy
                .filter { projectIds.isEmpty || ($0.projectId.map(projectIds.contains) ?? false) }
                .map(MobileBriefingEntry.document)
        }
        if let start = timeRange.startDate(now: now, calendar: calendar) {
            result = result.filter { $0.createdAt >= start }
        }
        let order: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) }
        )
        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            let lhsOrder = lhs.projectId.flatMap { order[$0] } ?? Int.max
            let rhsOrder = rhs.projectId.flatMap { order[$0] } ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Splits newest-first entries into day sections.
    static func daySections(_ entries: [MobileBriefingEntry], calendar: Calendar = .current) -> [MobileBriefingDaySection] {
        var sections: [MobileBriefingDaySection] = []
        var current: (day: Date, entries: [MobileBriefingEntry])?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let existing = current, existing.day == day {
                current?.entries.append(entry)
            } else {
                if let existing = current {
                    sections.append(MobileBriefingDaySection(day: existing.day, entries: existing.entries))
                }
                current = (day, [entry])
            }
        }
        if let existing = current {
            sections.append(MobileBriefingDaySection(day: existing.day, entries: existing.entries))
        }
        return sections
    }
}

// MARK: - Timeline view

/// Day-sectioned briefing timeline: a pinned date header per day, and a
/// vertical rail with one dot per row of cards, like the desktop timeline.
struct MobileBriefingTimeline<Card: View>: View {
    let sections: [MobileBriefingDaySection]
    var columnCount: Int = 1
    @ViewBuilder var card: (MobileBriefingEntry) -> Card

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                Section {
                    let rows = Self.rows(section.entries, columnCount: columnCount)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        MobileBriefingTimelineRow(
                            time: row.entries.first?.createdAt ?? section.day,
                            isLast: index == rows.count - 1
                        ) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(row.entries) { entry in
                                    card(entry)
                                        .frame(maxWidth: .infinity, alignment: .top)
                                }
                                // Keep a partial last row aligned to the grid.
                                ForEach(row.entries.count..<columnCount, id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                        }
                    }
                } header: {
                    MobileBriefingDayHeader(section: section)
                        .id(section.id)
                }
            }
        }
    }

    private struct Row: Identifiable {
        let entries: [MobileBriefingEntry]
        var id: String { entries.map(\.id).joined(separator: "|") }
    }

    private static func rows(_ entries: [MobileBriefingEntry], columnCount: Int) -> [Row] {
        let count = max(1, columnCount)
        return stride(from: 0, to: entries.count, by: count).map {
            Row(entries: Array(entries[$0..<min($0 + count, entries.count)]))
        }
    }
}

private struct MobileBriefingDayHeader: View {
    let section: MobileBriefingDaySection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            Text(section.entries.count == 1 ? "1 briefing" : "\(section.entries.count) briefings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(MobileCard.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("briefing-day-header")
    }
}

/// One row of the timeline: the rail (line + dot + time) and its cards.
private struct MobileBriefingTimelineRow<Content: View>: View {
    let time: Date
    let isLast: Bool
    @ViewBuilder var content: Content

    private static var dotTop: CGFloat { 22 }
    private static var railWidth: CGFloat { 14 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                // The line runs to the next row; the last row stops at its dot.
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
                    .frame(maxHeight: isLast ? Self.dotTop : .infinity, alignment: .top)
                Circle()
                    .fill(.tint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(MobileCard.pageBackground, lineWidth: 2))
                    .padding(.top, Self.dotTop - 5)
            }
            .frame(width: Self.railWidth)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 6) {
                Text(time, format: .dateTime.hour().minute())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, Self.dotTop - 8)
                content
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Scrubber

/// Fast-scroll rail for long timelines (the mobile counterpart of the desktop
/// scrubber). Dragging shows the day under the finger and jumps to it.
struct MobileBriefingTimelineScrubber: View {
    let sections: [MobileBriefingDaySection]
    let onSelect: (MobileBriefingDaySection) -> Void

    @State private var dragIndex: Int?
    @State private var dragY: CGFloat = 0
    private let selection = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(dragIndex == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                    .frame(width: dragIndex == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 4)

                if let dragIndex, sections.indices.contains(dragIndex) {
                    Text(sections[dragIndex].title)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: -24, y: min(max(0, dragY - 16), height - 32))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragIndex == nil { selection.prepare() }
                        dragY = value.location.y
                        let fraction = min(max(0, value.location.y / height), 0.9999)
                        let index = Int(fraction * CGFloat(sections.count))
                        guard index != dragIndex else { return }
                        withAnimation(.easeOut(duration: 0.15)) { dragIndex = index }
                        selection.selectionChanged()
                        onSelect(sections[index])
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { dragIndex = nil }
                    }
            )
        }
        .frame(width: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefing timeline")
        .accessibilityHint("Drag to jump to a day")
        .accessibilityIdentifier("briefing-timeline-scrubber")
    }
}

// MARK: - Filter menu

struct MobileBriefingFilterMenu: View {
    @Binding var filters: MobileBriefingFilters
    let projects: [Project]

    var body: some View {
        Menu {
            Picker("Show", selection: $filters.kind) {
                ForEach(MobileBriefingFilters.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            Picker("Time", selection: $filters.timeRange) {
                ForEach(MobileBriefingFilters.TimeRange.allCases, id: \.self) { range in
                    Text(range.title).tag(range)
                }
            }
            Picker("Branches", selection: $filters.currentBranchOnly) {
                Text("All branches").tag(false)
                Text("Current branch").tag(true)
            }
            if projects.count > 1 {
                Section("Projects") {
                    Button {
                        filters.projectIds.removeAll()
                    } label: {
                        selectionLabel("All projects", isSelected: filters.projectIds.isEmpty)
                    }
                    ForEach(projects) { project in
                        Button {
                            if filters.projectIds.contains(project.id) {
                                filters.projectIds.remove(project.id)
                            } else {
                                filters.projectIds.insert(project.id)
                            }
                        } label: {
                            selectionLabel(project.name, isSelected: filters.projectIds.contains(project.id))
                        }
                    }
                }
            }
            if filters.isActive {
                Section {
                    Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                        filters = MobileBriefingFilters()
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: filters.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .onChange(of: filters) { _, _ in MobileHaptics.buttonTap() }
        .accessibilityIdentifier("briefing-filter-menu")
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
