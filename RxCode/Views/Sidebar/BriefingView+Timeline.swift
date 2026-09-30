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

    static func sectionTitleRowId(_ section: BriefingDaySection) -> String {
        "title::\(section.id)"
    }

    /// A day title row followed by one row per line of cards. Columns are sized
    /// to the available width, and each card row stretches its cards to the
    /// tallest one so cards side by side share the same height.
    func sectionRows(_ section: BriefingDaySection) -> [BriefingTimelineRow] {
        let columnCount = max(1, min(4, Int(availableWidth / 420)))
        let cardRows = stride(from: 0, to: section.entries.count, by: columnCount).map {
            Array(section.entries[$0..<min($0 + columnCount, section.entries.count)])
        }

        let title = BriefingTimelineRow(id: Self.sectionTitleRowId(section), estimatedHeight: 54) {
            AnyView(
                sectionTitle(section)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    .briefingTimelineRowInsets()
            )
        }
        return [title] + cardRows.enumerated().map { index, row in
            BriefingTimelineRow(
                id: "cards::\(columnCount)::" + row.map(\.id).joined(separator: "|"),
                estimatedHeight: 320
            ) {
                AnyView(
                    cardRow(row, columnCount: columnCount)
                        .padding(.top, index == 0 ? 0 : 16)
                        .briefingTimelineRowInsets()
                )
            }
        }
    }

    private func sectionTitle(_ section: BriefingDaySection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.sectionTitle(for: section.day))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(section.entries.count == 1 ? "1 briefing" : "\(section.entries.count) briefings")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
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

    private func cardRow(_ row: [BriefingEntry], columnCount: Int) -> some View {
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
        let message = kindFilter == .document
            ? "No document briefings match the selected projects."
            : "No briefings match the selected projects."
        return emptyState(
            icon: "line.3.horizontal.decrease.circle",
            title: "Nothing to Show",
            message: message
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

extension View {
    /// Horizontal insets and max width shared by every timeline row.
    func briefingTimelineRowInsets() -> some View {
        padding(.horizontal, 28)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
