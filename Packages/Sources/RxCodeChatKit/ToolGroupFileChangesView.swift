import SwiftUI
import RxCodeCore

/// The files and lines changed by the tools in a single disclosure group.
struct ToolGroupFileChangesView: View {
    let tools: [ToolCall]

    var body: some View {
        let totals = tools.reduce(into: Totals()) { $0.include($1) }
        let fileCount = totals.paths.count
        if fileCount > 0 {
            let fileLabel = fileCount == 1
                ? Text("1 file changed", bundle: .module)
                : Text("\(fileCount) files changed", bundle: .module)
            let compactFileLabel = fileCount == 1
                ? Text("1 file", bundle: .module)
                : Text("\(fileCount) files", bundle: .module)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    fileLabel.fixedSize(horizontal: true, vertical: false)
                    compactFileLabel.fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .accessibilityLabel(fileLabel)

                if totals.added > 0 {
                    Text("+\(totals.added)")
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text("\(totals.added) lines added", bundle: .module))
                }
                if totals.removed > 0 {
                    Text("−\(totals.removed)")
                        .foregroundStyle(ClaudeTheme.statusError)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text("\(totals.removed) lines removed", bundle: .module))
                }
            }
            .font(.system(size: ClaudeTheme.messageSize(11), weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private struct Totals {
        var paths: Set<String> = []
        var added = 0
        var removed = 0

        mutating func include(_ tool: ToolCall) {
            let detectedChanges = tool.detectedShellFileChanges
            if !detectedChanges.isEmpty {
                // A shell command can change files even if it exits with an error.
                for change in detectedChanges {
                    record(path: change.path, added: change.addedLines, removed: change.removedLines)
                }
                return
            }

            guard tool.result != nil, !tool.isError else { return }
            let hunks = tool.fileEditHunks
            if !hunks.isEmpty, let path = tool.editedFilePath {
                let isWrite = tool.name.lowercased() == "write"
                for hunk in hunks where isWrite || hunk.oldString != hunk.newString {
                    let counts = hunk.lineCounts
                    record(path: path, added: counts.added, removed: counts.removed)
                }
            } else {
                for change in tool.fileChangeDiffs {
                    let counts = change.lineCounts
                    record(path: change.path, added: counts.added, removed: counts.removed)
                }
            }
        }

        private mutating func record(path: String, added: Int, removed: Int) {
            guard !path.isEmpty else { return }
            paths.insert(path)
            self.added += added
            self.removed += removed
        }
    }
}
