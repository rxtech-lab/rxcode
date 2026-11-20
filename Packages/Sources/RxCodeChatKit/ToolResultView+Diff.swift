import SwiftUI
import RxCodeCore

extension ToolResultView {
    // MARK: - Edit Diff

    var isEditTool: Bool {
        toolNameLower == "edit" || toolNameLower == "multiedit" || toolNameLower == "multi_edit"
    }

    var hasExpandableContent: Bool {
        if isEditTool, (toolCall.input["old_string"]?.stringValue != nil
                        && toolCall.input["new_string"]?.stringValue != nil) {
            return true
        }
        if isEditTool, !toolCall.fileChangeDiffs.isEmpty {
            return true
        }
        if toolNameLower == "write", toolCall.input["content"]?.stringValue != nil {
            return true
        }
        return false
    }

    func editHunksFromToolInput() -> [PreviewFile.EditHunk] {
        guard isEditTool || toolNameLower == "write" else { return [] }
        return toolCall.fileEditHunks
    }

    func editDiffView(oldString: String, newString: String) -> some View {
        let (trimmedOld, trimmedNew) = stripCommonIndent(
            old: oldString.components(separatedBy: .newlines),
            new: newString.components(separatedBy: .newlines)
        )
        // When oldString is fully empty (new file creation) the split yields a
        // single empty line that renders as a lone `-` row above the content.
        // Drop it so the diff is purely additions.
        let removedSource = oldString.isEmpty ? [] : trimmedOld
        let addedSource = newString.isEmpty ? [] : trimmedNew
        let removedLines = removedSource.map { ("-", $0, false) }
        let addedLines = addedSource.map { ("+", $0, true) }
        let allLines = removedLines + addedLines

        let collapseThreshold = 12
        let needsToggle = allLines.count > collapseThreshold
        let visibleLines = needsToggle && !isDiffExpanded
            ? Array(allLines.prefix(collapseThreshold))
            : allLines

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { idx, item in
                let (prefix, text, isAdded) = item
                ChatTextContentView(
                    prefix + " " + text,
                    size: ClaudeTheme.messageSize(12),
                    design: .monospaced,
                    color: isAdded ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background((isAdded ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError).opacity(0.06))
                    .transition(.asymmetric(
                        insertion: .move(edge: isAdded ? .leading : .trailing)
                            .combined(with: .opacity),
                        removal: .opacity
                    ))
                    .animation(
                        .easeOut(duration: 0.28).delay(Double(idx) * 0.015),
                        value: visibleLines.count
                    )
            }

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDiffExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if isDiffExpanded {
                                Text("Show less", bundle: .module)
                            } else {
                                Text("Show more", bundle: .module)
                            }
                        }
                        .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                        Image(systemName: isDiffExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .textSelection(.enabled)
    }

    func fileChangeDiffsView(_ changes: [ToolCall.FileChangeDiff]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    if changes.count > 1 {
                        Text(URL(fileURLWithPath: change.path).lastPathComponent)
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    rawUnifiedDiffView(change.diff)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func rawUnifiedDiffView(_ diff: String) -> some View {
        let rawLines = diff.components(separatedBy: .newlines)
        // Codex's `changes[].diff` for a brand-new file is sometimes just the
        // file's content with no `+`/`-`/`@@` markers. Without prefixes the
        // renderer would draw every line as plain text — exactly the
        // "no diff changes shown" symptom. Detect that shape and synthesize
        // `+` prefixes so additions render in green.
        let hasAnyMarker = rawLines.contains {
            $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@")
        }
        let lines: [String] = hasAnyMarker ? rawLines : rawLines.map { line in
            line.isEmpty ? line : "+" + line
        }
        let collapseThreshold = 18
        let needsToggle = lines.count > collapseThreshold
        let visibleLines = needsToggle && !isDiffExpanded
            ? Array(lines.prefix(collapseThreshold))
            : lines

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                ChatTextContentView(
                    line.isEmpty ? " " : line,
                    size: ClaudeTheme.messageSize(12),
                    design: .monospaced,
                    color: diffLineColor(line)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(diffLineBackground(line))
            }

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDiffExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(isDiffExpanded ? "Show less" : "Show more", bundle: .module)
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                        Image(systemName: isDiffExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError }
        if line.hasPrefix("@@") { return ClaudeTheme.accent }
        return ClaudeTheme.textPrimary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess.opacity(0.06) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError.opacity(0.06) }
        if line.hasPrefix("@@") { return ClaudeTheme.accent.opacity(0.08) }
        return Color.clear
    }
}
