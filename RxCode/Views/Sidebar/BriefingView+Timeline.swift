import SwiftUI
import Foundation
import RxCodeCore

// MARK: - Timeline

extension BriefingView {
    func daySections(_ entries: [BriefingEntry]) -> [BriefingDaySection] {
        let calendar = Calendar.current
        var sections: [BriefingDaySection] = []
        var current: (day: Date, entries: [BriefingEntry])?
        // `entries` is already sorted newest-first, so days arrive in order.
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let existing = current, existing.day == day {
                current?.entries.append(entry)
            } else {
                if let existing = current {
                    sections.append(BriefingDaySection(day: existing.day, entries: existing.entries))
                }
                current = (day, [entry])
            }
        }
        if let existing = current {
            sections.append(BriefingDaySection(day: existing.day, entries: existing.entries))
        }
        return sections
    }

    func timelineMarkers(_ sections: [BriefingDaySection]) -> [BriefingTimelineMarker] {
        sections.compactMap { section in
            guard let offset = sectionOffsets[section.id] else { return nil }
            return BriefingTimelineMarker(id: section.id, date: section.day, offset: offset)
        }
        .sorted { $0.offset < $1.offset }
    }

    func daySection(_ section: BriefingDaySection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.sectionTitle(for: section.day))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text(section.entries.count == 1 ? "1 briefing" : "\(section.entries.count) briefings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .accessibilityAddTraits(.isHeader)

            briefingGrid(section.entries)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(Self.timelineCoordinateSpace)).minY
        } action: { newValue in
            sectionOffsets[section.id] = newValue
        }
    }

    static func sectionTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    /// Render cards lazily in timeline order, with columns sized to the
    /// available width. Each row stretches its cards to the tallest one so
    /// cards side by side share the same height.
    func briefingGrid(_ entries: [BriefingEntry]) -> some View {
        let columnCount = max(1, min(4, Int(availableWidth / 420)))
        let rows = stride(from: 0, to: entries.count, by: columnCount).map {
            Array(entries[$0..<min($0 + columnCount, entries.count)])
        }
        return LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row) { entry in
                        entryCard(entry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .briefingCardMotion()
                    }
                    // Keep a partial last row aligned to the column grid.
                    ForEach(row.count..<columnCount, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Cards slide in and out as filters change instead of popping.
        .animation(.snappy(duration: 0.3), value: entries.map(\.id))
    }

    @ViewBuilder
    func entryCard(_ entry: BriefingEntry) -> some View {
        switch entry {
        case .project(let group):
            groupCard(group)
        case .document(let document):
            BriefingDocumentCard(
                document: document,
                project: document.projectId.flatMap { projectsById[$0] },
                maximumPreviewHeight: Self.maximumSummaryPreviewHeight,
                onOpen: { presentedDocument = document },
                onDelete: { documentToDelete = document }
            )
        }
    }

    var filteredEmptyState: some View {
        let message: String
        if kindFilter == .document {
            message = "No document briefings match the selected projects."
        } else if showAllBranches {
            message = "No briefings match the selected projects."
        } else {
            message = "No briefings for the current branch. Switch to All branches to see other branches."
        }
        return emptyState(
            icon: "line.3.horizontal.decrease.circle",
            title: "Nothing to Show",
            message: message
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}
