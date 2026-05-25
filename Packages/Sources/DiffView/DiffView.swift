import SwiftUI
import RxCodeCore

/// Pure-SwiftUI GitHub-style diff renderer. Works identically on macOS, iOS,
/// and any other SwiftUI platform — no `NSTextView` / `UITextView` involvement.
///
/// Layout:
///   - Two gutter columns (old / new line numbers) when both sides have line
///     numbers — i.e. an in-place edit.
///   - One gutter column when only one side has line numbers — i.e. a freshly
///     created file (every row is an addition) or a fully removed file.
///   - No gutter at all when no line numbers are present (e.g. hunk-only
///     edit previews).
///
/// Long lines can be displayed in two modes:
///   - `.wrap` (default): each row wraps to as many visual lines as needed.
///   - `.scroll`: each row is a single line; the body scrolls horizontally
///     while the gutter stays pinned on the left.
/// A small toggle in the top-right switches between modes.
public struct DiffView: View {
    /// Two ways to handle source lines that are wider than the viewport.
    public enum LineDisplay: String, CaseIterable, Sendable {
        case wrap
        case scroll
    }

    private let lines: [DiffLine]
    private let showsBackground: Bool
    private let showsControls: Bool
    @State private var display: LineDisplay

    public init(
        lines: [DiffLine],
        showsBackground: Bool = true,
        showsControls: Bool = true,
        initialDisplay: LineDisplay = .wrap
    ) {
        self.lines = lines
        self.showsBackground = showsBackground
        self.showsControls = showsControls
        self._display = State(initialValue: initialDisplay)
    }

    public var body: some View {
        let layout = GutterLayout(lines: lines)
        ZStack(alignment: .topTrailing) {
            content(layout: layout)
            if showsControls {
                DisplayModeToggle(display: $display)
                    .padding(6)
            }
        }
        .background(showsBackground ? ClaudeTheme.codeBackground : Color.clear)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func content(layout: GutterLayout) -> some View {
        switch display {
        case .wrap:
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffRow(line: line, layout: layout, wraps: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .scroll:
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    // Sticky gutter column — sits outside the horizontal
                    // scroll view so line numbers stay anchored on the left.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            DiffRowGutter(line: line, layout: layout)
                        }
                    }
                    // Horizontally scrollable body — marker + code text.
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                DiffRowBody(line: line, layout: layout, wraps: false)
                            }
                        }
                        .frame(minWidth: 0, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Gutter Layout

/// Pre-computed gutter sizing. Determined once from the full line set so every
/// row aligns and we know up-front whether to render one column or two.
struct GutterLayout {
    let showOld: Bool
    let showNew: Bool
    let oldDigits: Int
    let newDigits: Int

    init(lines: [DiffLine]) {
        // GitHub-style behavior: hide the old-line gutter when the diff has no
        // removed rows (e.g. a brand-new file, or a pure-addition edit), and
        // hide the new-line gutter when the diff has no added rows (e.g. a
        // full deletion). Context rows that carry old numbers alone shouldn't
        // force a two-column layout — they're just positional info.
        let hasRemovals = lines.contains { $0.kind == .removed }
        let hasAdditions = lines.contains { $0.kind == .added }
        let maxOld = lines.compactMap(\.oldLineNumber).max() ?? 0
        let maxNew = lines.compactMap(\.newLineNumber).max() ?? 0
        self.showOld = hasRemovals && maxOld > 0
        self.showNew = (hasAdditions || !hasRemovals) && maxNew > 0
        self.oldDigits = max(String(max(maxOld, 1)).count, 2)
        self.newDigits = max(String(max(maxNew, 1)).count, 2)
    }

    var columnCount: Int {
        (showOld ? 1 : 0) + (showNew ? 1 : 0)
    }
}

// MARK: - Row (combined)

/// Combined gutter + marker + content row. Used in `.wrap` mode where there
/// is no horizontal scroll, so a single HStack is sufficient.
private struct DiffRow: View {
    let line: DiffLine
    let layout: GutterLayout
    let wraps: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffRowGutter(line: line, layout: layout)
            DiffRowBody(line: line, layout: layout, wraps: wraps)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row Gutter

private struct DiffRowGutter: View {
    let line: DiffLine
    let layout: GutterLayout

    var body: some View {
        let isHeader = line.kind == .hunk || line.kind == .meta
        HStack(spacing: 0) {
            if layout.showOld {
                GutterCell(
                    number: isHeader ? nil : line.oldLineNumber,
                    digits: layout.oldDigits
                )
            }
            if layout.showNew {
                GutterCell(
                    number: isHeader ? nil : line.newLineNumber,
                    digits: layout.newDigits
                )
            }
        }
        .frame(minHeight: DiffMetrics.rowMinHeight, alignment: .top)
    }
}

// MARK: - Row Metrics

/// Minimum row height shared between the sticky gutter column and the
/// horizontally scrolling body in `.scroll` mode, so the two columns align
/// row-for-row even though their fonts differ slightly.
enum DiffMetrics {
    static var rowMinHeight: CGFloat {
        // ~lineHeight(12pt monospaced) + vertical padding(1 + 1).
        ClaudeTheme.messageSize(12) * 1.35 + 2
    }
}

// MARK: - Row Body (marker + text)

private struct DiffRowBody: View {
    let line: DiffLine
    let layout: GutterLayout
    let wraps: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            marker
            content
        }
        .frame(
            maxWidth: wraps ? .infinity : nil,
            minHeight: DiffMetrics.rowMinHeight,
            alignment: .leading
        )
        .background(rowBackground)
    }

    @ViewBuilder
    private var marker: some View {
        switch line.kind {
        case .added:
            markerCell("+", color: ClaudeTheme.statusSuccess)
        case .removed:
            markerCell("-", color: ClaudeTheme.statusError)
        case .context:
            markerCell(" ", color: ClaudeTheme.textTertiary)
        case .hunk, .meta:
            if layout.columnCount > 0 {
                markerCell(" ", color: ClaudeTheme.textTertiary)
            }
        }
    }

    private func markerCell(_ symbol: String, color: Color) -> some View {
        Text(symbol)
            .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14, alignment: .center)
    }

    private var content: some View {
        textView
            .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
            .foregroundStyle(textColor)
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 1)
            .fixedSize(horizontal: !wraps, vertical: true)
    }

    @ViewBuilder
    private var textView: some View {
        if wraps {
            Text(bodyText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        } else {
            Text(bodyText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var bodyText: String {
        let raw = line.text
        switch line.kind {
        case .added where raw.hasPrefix("+"):
            return String(raw.dropFirst())
        case .removed where raw.hasPrefix("-"):
            return String(raw.dropFirst())
        case .context where raw.hasPrefix(" "):
            return String(raw.dropFirst())
        default:
            return raw
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .added:   return ClaudeTheme.statusSuccess
        case .removed: return ClaudeTheme.statusError
        case .hunk:    return ClaudeTheme.textTertiary
        case .meta:    return ClaudeTheme.textTertiary
        case .context: return ClaudeTheme.textPrimary
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .added:   return ClaudeTheme.statusSuccess.opacity(0.12)
        case .removed: return ClaudeTheme.statusError.opacity(0.12)
        case .hunk:    return ClaudeTheme.surfaceSecondary.opacity(0.6)
        case .meta, .context: return .clear
        }
    }
}

// MARK: - Gutter Cell

private struct GutterCell: View {
    let number: Int?
    let digits: Int

    var body: some View {
        Text(numberString)
            .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .frame(minWidth: width, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(ClaudeTheme.surfaceSecondary.opacity(0.35))
    }

    private var numberString: String {
        number.map(String.init) ?? ""
    }

    private var width: CGFloat {
        // Roughly the width of `digits` monospaced glyphs at 11pt.
        CGFloat(digits) * 7.5
    }
}

// MARK: - Display Mode Toggle

private struct DisplayModeToggle: View {
    @Binding var display: DiffView.LineDisplay

    var body: some View {
        Button {
            display = (display == .wrap) ? .scroll : .wrap
        } label: {
            Image(systemName: iconName)
                .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(ClaudeTheme.surfaceSecondary.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(ClaudeTheme.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var iconName: String {
        switch display {
        case .wrap:   return "arrow.left.and.right"
        case .scroll: return "text.alignleft"
        }
    }

    private var helpText: String {
        switch display {
        case .wrap:   return "Switch to horizontal scroll"
        case .scroll: return "Switch to wrap"
        }
    }
}
