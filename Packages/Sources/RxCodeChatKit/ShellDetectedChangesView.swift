import SwiftUI
import RxCodeCore

/// Inline per-command file-change list rendered immediately whenever a shell/script
/// tool call (`Bash`, `exec_command`, `run_command`, etc.) creates, modifies, or
/// deletes workspace files.
public struct ShellDetectedChangesView: View {
    public let changes: [DetectedShellFileChange]
    public var autoExpandWhenCompact: Bool

    @Environment(WindowState.self) private var windowState: WindowState?
    @State private var toggledPaths: Set<String> = []
    @State private var fullDiffPaths: Set<String> = []

    public init(changes: [DetectedShellFileChange], autoExpandWhenCompact: Bool = true) {
        self.changes = changes
        self.autoExpandWhenCompact = autoExpandWhenCompact
    }

    /// Aggregates detected shell file changes across multiple `ToolCall`s in a
    /// tool group while preserving first-seen file order.
    public static func aggregatedChanges(from tools: [ToolCall]) -> [DetectedShellFileChange] {
        var order: [String] = []
        var byPath: [String: DetectedShellFileChange] = [:]

        for tool in tools {
            for change in tool.detectedShellFileChanges {
                if let existing = byPath[change.path] {
                    let combinedKind: DetectedFileChangeKind
                    if change.kind == .deleted {
                        combinedKind = .deleted
                    } else if existing.kind == .created {
                        combinedKind = .created
                    } else {
                        combinedKind = change.kind
                    }
                    let mergedDiff = [existing.diff, change.diff]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    byPath[change.path] = DetectedShellFileChange(
                        path: change.path,
                        kind: combinedKind,
                        addedLines: existing.addedLines + change.addedLines,
                        removedLines: existing.removedLines + change.removedLines,
                        diff: mergedDiff,
                        isAmbiguous: existing.isAmbiguous || change.isAmbiguous
                    )
                } else {
                    order.append(change.path)
                    byPath[change.path] = change
                }
            }
        }

        return order.compactMap { byPath[$0] }
    }

    private var defaultExpanded: Bool {
        autoExpandWhenCompact && changes.count <= 2
    }

    private func isExpanded(_ path: String) -> Bool {
        defaultExpanded ? !toggledPaths.contains(path) : toggledPaths.contains(path)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(changes) { change in
                fileChangeCard(change)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: toggledPaths)
        .sensoryFeedback(.selection, trigger: fullDiffPaths)
        #endif
    }

    @ViewBuilder
    private func fileChangeCard(_ change: DetectedShellFileChange) -> some View {
        let expanded = isExpanded(change.path) && !change.diff.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    guard !change.diff.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if toggledPaths.contains(change.path) {
                            toggledPaths.remove(change.path)
                        } else {
                            toggledPaths.insert(change.path)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kindSymbol(change.kind))
                            .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                            .foregroundStyle(kindColor(change.kind))
                            .frame(width: 14, height: 14)

                        Text(change.fileName)
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let badge = kindBadgeLabel(change.kind) {
                            Text(badge)
                                .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                                .foregroundStyle(kindColor(change.kind))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(kindColor(change.kind).opacity(0.12), in: Capsule())
                        }

                        if change.isAmbiguous {
                            Text("Concurrent")
                                .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                                .foregroundStyle(ClaudeTheme.statusWarning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ClaudeTheme.statusWarning.opacity(0.12), in: Capsule())
                        }

                        statView(added: change.addedLines, removed: change.removedLines)

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                #if os(macOS)
                if let windowState {
                    HStack(spacing: 8) {
                        if change.kind != .deleted {
                            Button {
                                windowState.inspectorFile = PreviewFile(
                                    path: change.path,
                                    name: change.fileName
                                )
                            } label: {
                                Text("Open")
                                    .font(.system(size: ClaudeTheme.messageSize(11)))
                                    .foregroundStyle(ClaudeTheme.accent)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .pointerCursorOnHover()
                        }

                        if !change.diff.isEmpty {
                            Button {
                                windowState.diffFile = PreviewFile(
                                    path: change.path,
                                    name: change.fileName,
                                    editHunks: [change.hunk],
                                    showFullFileDiff: change.kind != .deleted,
                                    preferHunks: change.isAmbiguous
                                )
                            } label: {
                                Text("Diff")
                                    .font(.system(size: ClaudeTheme.messageSize(11)))
                                    .foregroundStyle(ClaudeTheme.textSecondary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .pointerCursorOnHover()
                        }
                    }
                }
                #endif

                if !change.diff.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if toggledPaths.contains(change.path) {
                                toggledPaths.remove(change.path)
                            } else {
                                toggledPaths.insert(change.path)
                            }
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if expanded {
                ClaudeThemeDivider()
                inlineUnifiedDiff(change)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.surfacePrimary.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell-detected-change-\(change.fileName)")
    }

    @ViewBuilder
    private func statView(added: Int, removed: Int) -> some View {
        HStack(spacing: 4) {
            if added > 0 || removed == 0 {
                Text("+\(added)")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            }
            if removed > 0 {
                Text("−\(removed)")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.statusError)
            }
        }
    }

    @ViewBuilder
    private func inlineUnifiedDiff(_ change: DetectedShellFileChange) -> some View {
        let lines = change.diff.components(separatedBy: .newlines).filter { line in
            !line.hasPrefix("--- ") && !line.hasPrefix("+++ ")
        }
        let collapseThreshold = 12
        let showFull = fullDiffPaths.contains(change.path)
        let needsToggle = lines.count > collapseThreshold
        let visibleLines = needsToggle && !showFull
            ? Array(lines.prefix(collapseThreshold))
            : lines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                ChatTextContentView(
                    line.isEmpty ? " " : line,
                    size: ClaudeTheme.messageSize(11.5),
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
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if fullDiffPaths.contains(change.path) {
                            fullDiffPaths.remove(change.path)
                        } else {
                            fullDiffPaths.insert(change.path)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(showFull ? "Show less" : "Show more (\(lines.count - collapseThreshold) more lines)")
                            .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                        Image(systemName: showFull ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(9), weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.surfacePrimary.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .textSelection(.enabled)
    }

    private func kindSymbol(_ kind: DetectedFileChangeKind) -> String {
        switch kind {
        case .created: "doc.badge.plus"
        case .modified: "pencil"
        case .deleted: "trash"
        }
    }

    private func kindColor(_ kind: DetectedFileChangeKind) -> Color {
        switch kind {
        case .created: ClaudeTheme.statusSuccess
        case .modified: ClaudeTheme.statusWarning
        case .deleted: ClaudeTheme.statusError
        }
    }

    private func kindBadgeLabel(_ kind: DetectedFileChangeKind) -> String? {
        switch kind {
        case .created: "New"
        case .modified: nil
        case .deleted: "Deleted"
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return ClaudeTheme.statusSuccess }
        if line.hasPrefix("-") { return ClaudeTheme.statusError }
        if line.hasPrefix("@@") { return ClaudeTheme.accent }
        return ClaudeTheme.textSecondary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") { return ClaudeTheme.statusSuccess.opacity(0.06) }
        if line.hasPrefix("-") { return ClaudeTheme.statusError.opacity(0.06) }
        if line.hasPrefix("@@") { return ClaudeTheme.accent.opacity(0.07) }
        return Color.clear
    }
}
