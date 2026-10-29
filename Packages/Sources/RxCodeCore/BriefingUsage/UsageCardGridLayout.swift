import SwiftUI

/// Dense first-fit packing, like widget grids: each card takes the earliest
/// free slot that fits its span, so smaller cards backfill holes left by
/// larger ones instead of leaving gaps.
public enum UsageCardGridPacking {
    public struct Placement: Equatable, Sendable {
        public var column: Int
        public var row: Int
        public var columnSpan: Int
        public var rowSpan: Int
        public init(column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
            self.column = column; self.row = row; self.columnSpan = columnSpan; self.rowSpan = rowSpan
        }
    }

    public static func columnCount(width: CGFloat, minimumColumnWidth: CGFloat, spacing: CGFloat, maximum: Int) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return min(maximum, max(1, Int((width + spacing) / (minimumColumnWidth + spacing))))
    }

    public static func pack(_ sizes: [UsageCardSize], columnCount: Int) -> [Placement] {
        let columns = max(1, columnCount)
        var occupied: [[Bool]] = []
        func isFree(row: Int, column: Int, width: Int, height: Int) -> Bool {
            for r in row..<(row + height) where r < occupied.count {
                for c in column..<(column + width) where occupied[r][c] { return false }
            }
            return true
        }
        return sizes.map { size in
            let width = min(size.columns, columns)
            // A card squeezed to fewer columns keeps its row span, so a large
            // card on a narrow screen stays tall instead of collapsing.
            let height = size.rows
            var row = 0
            while true {
                if let column = (0...(columns - width)).first(where: { isFree(row: row, column: $0, width: width, height: height) }) {
                    while occupied.count < row + height { occupied.append(Array(repeating: false, count: columns)) }
                    for r in row..<(row + height) { for c in column..<(column + width) { occupied[r][c] = true } }
                    return Placement(column: column, row: row, columnSpan: width, rowSpan: height)
                }
                row += 1
            }
        }
    }

    /// Packs, then grows each card right and then down into cells nothing
    /// else uses, so every row reaches the full width and holes close up.
    public static func arrange(_ sizes: [UsageCardSize], columnCount: Int) -> [Placement] {
        let columns = max(1, columnCount)
        var placements = pack(sizes, columnCount: columns)
        let rows = rowCount(placements)
        var occupied = Array(repeating: Array(repeating: false, count: columns), count: rows)
        for p in placements { for r in p.row..<(p.row + p.rowSpan) { for c in p.column..<(p.column + p.columnSpan) { occupied[r][c] = true } } }
        func claim(_ cells: [(Int, Int)]) -> Bool {
            guard !cells.isEmpty, cells.allSatisfy({ $0.0 < rows && $0.1 < columns && !occupied[$0.0][$0.1] }) else { return false }
            for (r, c) in cells { occupied[r][c] = true }
            return true
        }
        for index in placements.indices {
            var p = placements[index]
            while claim((p.row..<(p.row + p.rowSpan)).map { ($0, p.column + p.columnSpan) }) { p.columnSpan += 1 }
            placements[index] = p
        }
        for index in placements.indices {
            var p = placements[index]
            while claim((p.column..<(p.column + p.columnSpan)).map { (p.row + p.rowSpan, $0) }) { p.rowSpan += 1 }
            placements[index] = p
        }
        return placements
    }

    public static func rowCount(_ placements: [Placement]) -> Int {
        placements.map { $0.row + $0.rowSpan }.max() ?? 0
    }
}

private struct UsageCardSizeKey: LayoutValueKey {
    static let defaultValue: UsageCardSize = .medium
}

public extension View {
    /// Tags a subview of `UsageCardGridLayout` with its widget-style footprint.
    func usageCardSize(_ size: UsageCardSize) -> some View {
        layoutValue(key: UsageCardSizeKey.self, value: size)
    }
}

/// Lays out briefing usage cards on a grid of square-ish cells, sized like
/// macOS widgets (small = 1×1, medium = 2×1, large = 2×2, extra large = 4×2).
public struct UsageCardGridLayout: Layout {
    public var minimumColumnWidth: CGFloat
    public var rowHeight: CGFloat
    public var spacing: CGFloat
    public var maximumColumns: Int

    public init(minimumColumnWidth: CGFloat = 160, rowHeight: CGFloat = 170, spacing: CGFloat = 12, maximumColumns: Int = 8) {
        self.minimumColumnWidth = minimumColumnWidth; self.rowHeight = rowHeight
        self.spacing = spacing; self.maximumColumns = maximumColumns
    }

    public struct Cache {
        var width: CGFloat = -1
        var columns = 1
        var placements: [UsageCardGridPacking.Placement] = []
    }

    public func makeCache(subviews: Subviews) -> Cache { Cache() }
    public func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func resolve(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width || cache.placements.count != subviews.count else { return }
        cache.width = width
        cache.columns = UsageCardGridPacking.columnCount(
            width: width, minimumColumnWidth: minimumColumnWidth, spacing: spacing, maximum: maximumColumns)
        cache.placements = UsageCardGridPacking.arrange(subviews.map { $0[UsageCardSizeKey.self] }, columnCount: cache.columns)
    }

    private func idealWidth(subviews: Subviews) -> CGFloat {
        let columns = min(maximumColumns, max(1, subviews.map { $0[UsageCardSizeKey.self].columns }.max() ?? 1))
        return CGFloat(columns) * minimumColumnWidth + CGFloat(columns - 1) * spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth(subviews: subviews)
        resolve(width: width, subviews: subviews, cache: &cache)
        let rows = UsageCardGridPacking.rowCount(cache.placements)
        return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        resolve(width: bounds.width, subviews: subviews, cache: &cache)
        let columns = CGFloat(cache.columns)
        let cellWidth = (bounds.width - spacing * (columns - 1)) / columns
        for (subview, placement) in zip(subviews, cache.placements) {
            let span = CGFloat(placement.columnSpan), rowSpan = CGFloat(placement.rowSpan)
            let size = CGSize(width: cellWidth * span + spacing * (span - 1),
                              height: rowHeight * rowSpan + spacing * (rowSpan - 1))
            let origin = CGPoint(x: bounds.minX + CGFloat(placement.column) * (cellWidth + spacing),
                                 y: bounds.minY + CGFloat(placement.row) * (rowHeight + spacing))
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}
