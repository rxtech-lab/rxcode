import SwiftUI
import RxCodeCore

/// The files and lines changed by the tools in a single disclosure group.
struct ToolGroupFileChangesView: View {
    let tools: [ToolCall]

    #if os(macOS)
    @Environment(ChatBridge.self) private var chatBridge: ChatBridge?
    @State private var ignoreResult: (query: IgnoreQuery, ignoredPaths: Set<String>)?

    private struct IgnoreQuery: Equatable {
        let directory: String
        let paths: Set<String>
    }
    #endif

    var body: some View {
        #if os(macOS)
        let workingDirectory = chatBridge?.workingDirectory
        let changes = ToolGroupFileChanges(tools: tools, workingDirectory: workingDirectory)
        let query = workingDirectory.map { IgnoreQuery(directory: $0, paths: changes.paths) }
        let totals: ToolGroupFileChanges.Totals? = if query == nil {
            changes.totals()
        } else if let query, let ignoreResult, ignoreResult.query.directory == query.directory {
            // Keep confirmed files visible while Git checks newly changed paths.
            changes.totals(excluding: query.paths
                .subtracting(ignoreResult.query.paths)
                .union(ignoreResult.ignoredPaths))
        } else {
            nil
        }
        labels(totals)
            .task(id: query) {
                guard let query, !query.paths.isEmpty else { return }
                let paths = await GitHelper.ignoredChangePaths(query.paths, at: query.directory)
                guard !Task.isCancelled else { return }
                ignoreResult = (query, paths)
            }
        #else
        labels(ToolGroupFileChanges(tools: tools).totals())
        #endif
    }

    private func labels(_ totals: ToolGroupFileChanges.Totals?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let totals, totals.fileCount > 0 {
                let fileCount = totals.fileCount
                let fileLabel = fileCount == 1
                    ? Text("1 file changed", bundle: .module)
                    : Text("\(fileCount) files changed", bundle: .module)
                let compactFileLabel = fileCount == 1
                    ? Text("1 file", bundle: .module)
                    : Text("\(fileCount) files", bundle: .module)

                ViewThatFits(in: .horizontal) {
                    fileLabel.fixedSize(horizontal: true, vertical: false)
                    compactFileLabel.fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .accessibilityLabel(fileLabel)
                .modifier(ToolGroupCountTransition(count: fileCount))

                if totals.added > 0 {
                    Text("+\(totals.added)")
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text("\(totals.added) lines added", bundle: .module))
                        .modifier(ToolGroupCountTransition(count: totals.added))
                }
                if totals.removed > 0 {
                    Text("−\(totals.removed)")
                        .foregroundStyle(ClaudeTheme.statusError)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text("\(totals.removed) lines removed", bundle: .module))
                        .modifier(ToolGroupCountTransition(count: totals.removed))
                }
            }
        }
        .font(.system(size: ClaudeTheme.messageSize(11), weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct ToolGroupCountTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: count)
    }
}

struct ToolGroupFileChanges {
    typealias Totals = (fileCount: Int, added: Int, removed: Int)
    private var countsByPath: [String: (added: Int, removed: Int)] = [:]

    var paths: Set<String> { Set(countsByPath.keys) }

    init(tools: [ToolCall], workingDirectory: String? = nil) {
        for tool in tools {
            include(tool, workingDirectory: workingDirectory)
        }
    }

    func totals(excluding ignoredPaths: Set<String> = []) -> Totals {
        var totals: Totals = (0, 0, 0)
        for (path, counts) in countsByPath where !ignoredPaths.contains(path) {
            totals.fileCount += 1
            totals.added += counts.added
            totals.removed += counts.removed
        }
        return totals
    }

    private mutating func include(_ tool: ToolCall, workingDirectory: String?) {
        let directory = workingDirectory.map { root in
            guard let toolDirectory = tool.shellWorkingDirectory else { return root }
            return Self.absolutePath(toolDirectory, relativeTo: root)
        }
        let detectedChanges = tool.detectedShellFileChanges
        if !detectedChanges.isEmpty {
            // A shell command can change files even if it exits with an error.
            for change in detectedChanges {
                record(change.path, counts: (change.addedLines, change.removedLines), at: directory)
            }
            return
        }

        guard tool.result != nil, !tool.isError else { return }
        let hunks = tool.fileEditHunks
        if !hunks.isEmpty, let path = tool.editedFilePath {
            let isWrite = tool.name.lowercased() == "write"
            for hunk in hunks where isWrite || hunk.oldString != hunk.newString {
                record(path, counts: hunk.lineCounts, at: directory)
            }
        } else {
            for change in tool.fileChangeDiffs {
                record(change.path, counts: change.lineCounts, at: directory)
            }
        }
    }

    private mutating func record(_ path: String, counts: (added: Int, removed: Int), at directory: String?) {
        guard !path.isEmpty else { return }
        let key = directory.map { Self.absolutePath(path, relativeTo: $0) } ?? path
        countsByPath[key, default: (0, 0)].added += counts.added
        countsByPath[key, default: (0, 0)].removed += counts.removed
    }

    private static func absolutePath(_ path: String, relativeTo directory: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }
}
