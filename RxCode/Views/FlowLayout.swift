import SwiftUI

/// A layout that arranges its subviews left-to-right and wraps to a new line
/// whenever the next subview would overflow the available width. Subviews that
/// report a zero ideal size (e.g. empty `@ViewBuilder` conditionals) are
/// skipped so they don't leave phantom gaps. Used for the briefing card's
/// status chips, which can otherwise overflow a narrow card.
struct FlowLayout: Layout {
    /// Horizontal gap between items on the same row.
    var spacing: CGFloat = 6
    /// Vertical gap between wrapped rows.
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // Skip empty subviews so conditional chips don't add spacing.
            guard size.width > 0, size.height > 0 else { continue }

            if current.items.isEmpty {
                current.items.append((index, size))
                current.width = size.width
                current.height = size.height
            } else if current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
                current.items.append((index, size))
                current.width = size.width
                current.height = size.height
            } else {
                current.width += spacing + size.width
                current.height = max(current.height, size.height)
                current.items.append((index, size))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
