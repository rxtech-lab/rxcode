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
/// The caller owns the toggle (typically in a surrounding toolbar) — pass the
/// current mode in as `display`.
public struct DiffView: View {
    /// Two ways to handle source lines that are wider than the viewport.
    public enum LineDisplay: String, CaseIterable, Sendable {
        case wrap
        case scroll
    }

    private let lines: [DiffLine]
    private let showsBackground: Bool
    private let display: LineDisplay
    private let language: String?

    public init(
        lines: [DiffLine],
        showsBackground: Bool = true,
        display: LineDisplay = .wrap,
        language: String? = nil
    ) {
        self.lines = lines
        self.showsBackground = showsBackground
        self.display = display
        self.language = language
    }

    public var body: some View {
        let layout = GutterLayout(lines: lines)
        content(layout: layout)
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
                        DiffRow(line: line, layout: layout, wraps: true, language: language)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .scroll:
            GeometryReader { proxy in
                let viewportWidth = max(0, proxy.size.width - layout.width)
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        // Sticky gutter column — sits outside the horizontal
                        // scroll so line numbers stay anchored on the left.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                DiffRowGutter(line: line, layout: layout)
                            }
                        }
                        // Horizontally scrollable body. Constrain the viewport
                        // to the visible remainder; otherwise the vertical
                        // scroll layout can offer an effectively unbounded
                        // width and leave a large blank gap before the text.
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    DiffRowBody(
                                        line: line,
                                        layout: layout,
                                        wraps: false,
                                        language: language
                                    )
                                }
                            }
                            .frame(minWidth: viewportWidth, alignment: .leading)
                        }
                        .frame(width: viewportWidth, alignment: .leading)
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
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

    var width: CGFloat {
        (showOld ? columnWidth(digits: oldDigits) : 0)
        + (showNew ? columnWidth(digits: newDigits) : 0)
    }

    private func columnWidth(digits: Int) -> CGFloat {
        CGFloat(digits) * 7.5 + 8
    }
}

// MARK: - Row (combined)

/// Combined gutter + marker + content row. Used in `.wrap` mode where there
/// is no horizontal scroll, so a single HStack is sufficient.
private struct DiffRow: View {
    let line: DiffLine
    let layout: GutterLayout
    let wraps: Bool
    let language: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffRowGutter(line: line, layout: layout)
            DiffRowBody(line: line, layout: layout, wraps: wraps, language: language)
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
                    digits: layout.oldDigits,
                    side: .old
                )
            }
            if layout.showNew {
                GutterCell(
                    number: isHeader ? nil : line.newLineNumber,
                    digits: layout.newDigits,
                    side: .new
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

// MARK: - Row Body (marker + text, inlined as one Text)

private struct DiffRowBody: View {
    let line: DiffLine
    let layout: GutterLayout
    let wraps: Bool
    /// File-extension hint (e.g. "swift", "ts") used to syntax-highlight the
    /// body text. `nil` skips highlighting and falls back to a flat color.
    let language: String?

    var body: some View {
        textView
            .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
            // Keep the body flush with the gutter — any extra leading padding
            // here visually compounds the source code's own indentation and
            // makes deeply-nested lines look like they have a "huge gap" from
            // the left edge.
            .padding(.leading, 0)
            .padding(.trailing, 12)
            .padding(.vertical, 1)
            .fixedSize(horizontal: !wraps, vertical: true)
            .frame(
                maxWidth: wraps ? .infinity : nil,
                minHeight: DiffMetrics.rowMinHeight,
                alignment: .leading
            )
            .background(rowBackground)
    }

    @ViewBuilder
    private var textView: some View {
        if wraps {
            combinedText
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        } else {
            combinedText
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Marker + body merged into one `Text` so wrapped continuation lines align
    /// flush with the `+` / `-` itself, instead of sitting in a phantom column
    /// past the marker like they do when marker and body are separate views.
    private var combinedText: Text {
        let prefix: Text
        switch line.kind {
        case .added:
            prefix = Text("+ ").foregroundStyle(ClaudeTheme.statusSuccess)
        case .removed:
            prefix = Text("- ").foregroundStyle(ClaudeTheme.statusError)
        case .context:
            prefix = Text("  ").foregroundStyle(ClaudeTheme.textTertiary)
        case .hunk, .meta:
            prefix = layout.columnCount > 0
                ? Text("  ").foregroundStyle(ClaudeTheme.textTertiary)
                : Text("")
        }
        return prefix + bodyTextView
    }

    /// Body of the row. Uses `SyntaxHighlighter` for code rows when a language
    /// is known; falls back to the flat per-kind color otherwise. Hunk and meta
    /// rows are never tokenized — they're not source code.
    private var bodyTextView: Text {
        let isCode = line.kind == .added || line.kind == .removed || line.kind == .context
        if isCode, let language, !language.isEmpty {
            let attributed = SyntaxHighlighter.highlight(
                bodyText,
                language: language,
                fontSize: ClaudeTheme.messageSize(12)
            )
            return Text(attributed)
        }
        return Text(bodyText).foregroundStyle(textColor)
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
    enum Side {
        case old, new

        var help: String {
            switch self {
            case .old: return "Old line number (before)"
            case .new: return "New line number (after)"
            }
        }
    }

    let number: Int?
    let digits: Int
    let side: Side

    var body: some View {
        Text(numberString)
            .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .frame(minWidth: width, alignment: .trailing)
            .padding(.horizontal, 4) // tight, so the gutter doesn't dominate the row
            .padding(.vertical, 1)
            .background(ClaudeTheme.surfaceSecondary.opacity(0.35))
            .help(side.help)
            .accessibilityLabel(side.help)
    }

    private var numberString: String {
        number.map(String.init) ?? ""
    }

    private var width: CGFloat {
        // Roughly the width of `digits` monospaced glyphs at 11pt.
        CGFloat(digits) * 7.5
    }
}
