import SwiftUI
import RxCodeCore

/// Full, non-collapsing diff renderer for a single file. Used by the mobile
/// "View Changes" detail page, which owns a whole screen and therefore renders
/// every diff line. Accepts either a raw unified diff string (git changes) or a
/// set of old/new edit-hunk pairs (thread file edits).
///
/// The +/- coloring intentionally mirrors `ToolResultView`'s inline chat diffs.
public struct ChangeDiffView: View {
    private enum Source {
        case unified(String)
        case hunks([PreviewFile.EditHunk])
    }

    private let source: Source

    /// Renders a raw unified diff, e.g. `git diff` output.
    public init(unifiedDiff: String) {
        source = .unified(unifiedDiff)
    }

    /// Renders old/new replacement pairs as a removed-then-added diff.
    public init(hunks: [PreviewFile.EditHunk]) {
        source = .hunks(hunks)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch source {
            case .unified(let diff):
                unifiedRows(diff)
            case .hunks(let hunks):
                hunkRows(hunks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Unified diff

    @ViewBuilder
    private func unifiedRows(_ diff: String) -> some View {
        let lines = diff.components(separatedBy: .newlines)
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            diffRow(
                text: line.isEmpty ? " " : line,
                color: unifiedColor(line),
                background: unifiedBackground(line)
            )
        }
    }

    // MARK: - Edit hunks

    @ViewBuilder
    private func hunkRows(_ hunks: [PreviewFile.EditHunk]) -> some View {
        ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
            if index > 0 {
                Divider().padding(.vertical, 4)
            }
            let removed = hunk.oldString
                .components(separatedBy: .newlines)
                .map { ("- " + $0, ClaudeTheme.statusError, ClaudeTheme.statusError.opacity(0.06)) }
            let added = hunk.newString
                .components(separatedBy: .newlines)
                .map { ("+ " + $0, ClaudeTheme.statusSuccess, ClaudeTheme.statusSuccess.opacity(0.06)) }
            ForEach(Array((removed + added).enumerated()), id: \.offset) { _, item in
                diffRow(text: item.0, color: item.1, background: item.2)
            }
        }
    }

    // MARK: - Shared row

    private func diffRow(text: String, color: Color, background: Color) -> some View {
        ChatTextContentView(
            text,
            size: ClaudeTheme.messageSize(12),
            design: .monospaced,
            color: color
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(background)
    }

    private func unifiedColor(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError }
        if line.hasPrefix("@@") { return ClaudeTheme.accent }
        return ClaudeTheme.textPrimary
    }

    private func unifiedBackground(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess.opacity(0.06) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError.opacity(0.06) }
        if line.hasPrefix("@@") { return ClaudeTheme.accent.opacity(0.08) }
        return Color.clear
    }
}
