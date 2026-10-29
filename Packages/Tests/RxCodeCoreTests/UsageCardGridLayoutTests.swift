import Foundation
import Testing
@testable import RxCodeCore

@Suite("Usage card grid")
struct UsageCardGridLayoutTests {
    typealias Placement = UsageCardGridPacking.Placement

    @Test func defaultSizeFollowsStyleAndLegacyCardsDecode() throws {
        let integration = UUID()
        #expect(UsageCardConfiguration(integrationID: integration, style: "compact").cardSize == .small)
        #expect(UsageCardConfiguration(integrationID: integration).cardSize == .medium)
        #expect(UsageCardConfiguration(integrationID: integration, style: "metrics").cardSize == .large)
        #expect(UsageCardConfiguration(integrationID: integration, size: "xlarge").cardSize == .xlarge)
        #expect(UsageCardConfiguration(integrationID: integration, size: "unknown").cardSize == .medium)

        let legacy = Data(#"{"id":"\#(UUID())","integrationID":"\#(integration)","style":"metrics","isVisible":true,"showInMenuBar":false,"showInWidget":false}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageCardConfiguration.self, from: legacy)
        #expect(decoded.size == nil)
        #expect(decoded.cardSize == .large)
    }

    @Test func smallCardsBackfillGapsBesideLargeCards() {
        let placements = UsageCardGridPacking.pack([.large, .small, .small, .small, .small], columnCount: 4)
        #expect(placements == [
            Placement(column: 0, row: 0, columnSpan: 2, rowSpan: 2),
            Placement(column: 2, row: 0, columnSpan: 1, rowSpan: 1),
            Placement(column: 3, row: 0, columnSpan: 1, rowSpan: 1),
            Placement(column: 2, row: 1, columnSpan: 1, rowSpan: 1),
            Placement(column: 3, row: 1, columnSpan: 1, rowSpan: 1)
        ])
        #expect(UsageCardGridPacking.rowCount(placements) == 2)
    }

    @Test func laterCardsFillEarlierHoles() {
        // The medium card cannot fit beside the first small card in a
        // three-column grid's remaining slot, so the next small one does.
        let placements = UsageCardGridPacking.pack([.small, .medium, .medium, .small], columnCount: 3)
        #expect(placements[1] == Placement(column: 1, row: 0, columnSpan: 2, rowSpan: 1))
        #expect(placements[2] == Placement(column: 0, row: 1, columnSpan: 2, rowSpan: 1))
        #expect(placements[3] == Placement(column: 2, row: 1, columnSpan: 1, rowSpan: 1))
    }

    @Test func wideCardsClampToNarrowGrids() {
        let placements = UsageCardGridPacking.pack([.xlarge, .medium, .small], columnCount: 2)
        #expect(placements[0] == Placement(column: 0, row: 0, columnSpan: 2, rowSpan: 2))
        #expect(placements[1] == Placement(column: 0, row: 2, columnSpan: 2, rowSpan: 1))
        #expect(placements[2] == Placement(column: 0, row: 3, columnSpan: 1, rowSpan: 1))
        #expect(UsageCardGridPacking.pack([.large], columnCount: 1)[0].columnSpan == 1)
    }

    @Test func columnCountFitsMinimumWidth() {
        #expect(UsageCardGridPacking.columnCount(width: 343, minimumColumnWidth: 150, spacing: 16, maximum: 8) == 2)
        #expect(UsageCardGridPacking.columnCount(width: 700, minimumColumnWidth: 160, spacing: 12, maximum: 8) == 4)
        #expect(UsageCardGridPacking.columnCount(width: 4000, minimumColumnWidth: 160, spacing: 12, maximum: 8) == 8)
        #expect(UsageCardGridPacking.columnCount(width: 0, minimumColumnWidth: 160, spacing: 12, maximum: 8) == 1)
    }

    @Test func arrangeStretchesCardsToFillTheWidth() {
        // Five columns with only two-wide cards leaves the last column empty
        // after packing; arranging widens the cards beside it.
        let placements = UsageCardGridPacking.arrange([.large, .medium, .medium], columnCount: 5)
        #expect(placements == [
            Placement(column: 0, row: 0, columnSpan: 2, rowSpan: 2),
            Placement(column: 2, row: 0, columnSpan: 3, rowSpan: 1),
            Placement(column: 2, row: 1, columnSpan: 3, rowSpan: 1)
        ])
        let lone = UsageCardGridPacking.arrange([.medium, .medium, .small], columnCount: 4)
        #expect(lone[2] == Placement(column: 0, row: 1, columnSpan: 4, rowSpan: 1))
    }

    @Test func arrangeGrowsCardsDownIntoHoles() {
        let placements = UsageCardGridPacking.arrange([.large, .medium], columnCount: 4)
        #expect(placements[1] == Placement(column: 2, row: 0, columnSpan: 2, rowSpan: 2))
    }
}
