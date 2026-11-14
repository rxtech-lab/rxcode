import Foundation

// MARK: - Snapshot Diff Extractor

/// Extracted delta between two full-text snapshots of a single file.
public struct ExtractedSnapshotDiff: Sendable, Equatable {
    public let kind: DetectedFileChangeKind
    public let addedLines: Int
    public let removedLines: Int
    /// Unified diff formatted with `@@ -oldStart,oldCount +newStart,newCount @@` headers.
    public let unifiedDiff: String
    /// Anchored `(oldString, newString)` hunks suitable for `ThreadFileEdit` and
    /// `DiffComputation.buildFullFileEditDiffLines` reverse-application.
    public let editHunks: [PreviewFile.EditHunk]

    public init(
        kind: DetectedFileChangeKind,
        addedLines: Int,
        removedLines: Int,
        unifiedDiff: String,
        editHunks: [PreviewFile.EditHunk]
    ) {
        self.kind = kind
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.unifiedDiff = unifiedDiff
        self.editHunks = editHunks
    }
}

/// Pure, allocation-conscious line-diff extractor for `WorkspaceChangeTracker`.
public enum SnapshotDiffExtractor {
    private enum RawRow {
        case context(text: String, oldLine: Int, newLine: Int)
        case removed(text: String, oldLine: Int)
        case added(text: String, newLine: Int)

        var isChange: Bool {
            switch self {
            case .context: return false
            case .removed, .added: return true
            }
        }
    }

    /// Computes line counts, a compact unified diff, and anchored `EditHunk`s
    /// from `(before, after)` file snapshots (`nil` means absent on disk).
    /// Returns `nil` when there is no semantic change.
    public static func extract(
        before: String?,
        after: String?,
        contextLines: Int = 2,
        maxUnifiedLines: Int = 180
    ) -> ExtractedSnapshotDiff? {
        if before == nil, after == nil {
            return nil
        }
        if let before, let after, before == after {
            return nil
        }

        let kind: DetectedFileChangeKind
        if before == nil {
            kind = .created
        } else if after == nil {
            kind = .deleted
        } else {
            kind = .modified
        }

        let oldLines = splitContentLines(before ?? "")
        let newLines = splitContentLines(after ?? "")

        // Guard pathological files (> 8,000 lines) from quadratic Myers runtime
        // on background tasks: fall back to a fast prefix/suffix window diff.
        let rows: [RawRow]
        if oldLines.count + newLines.count > 8_000 {
            rows = buildTrimmedWindowRows(old: oldLines, new: newLines)
        } else {
            rows = buildCollectionDiffRows(old: oldLines, new: newLines)
        }

        var addedCount = 0
        var removedCount = 0
        for row in rows {
            switch row {
            case .added: addedCount += 1
            case .removed: removedCount += 1
            case .context: break
            }
        }

        let editHunks: [PreviewFile.EditHunk]
        switch kind {
        case .created:
            editHunks = [PreviewFile.EditHunk(oldString: "", newString: newLines.joined(separator: "\n"))]
        case .deleted:
            editHunks = [PreviewFile.EditHunk(oldString: oldLines.joined(separator: "\n"), newString: "")]
        case .modified:
            editHunks = buildAnchoredEditHunks(rows: rows, anchorLines: max(1, contextLines))
        }

        let unified = formatUnifiedDiff(
            rows: rows,
            contextLines: max(0, contextLines),
            maxLines: maxUnifiedLines
        )

        return ExtractedSnapshotDiff(
            kind: kind,
            addedLines: addedCount,
            removedLines: removedCount,
            unifiedDiff: unified,
            editHunks: editHunks
        )
    }

    // MARK: - Private Builders

    private static func splitContentLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func buildCollectionDiffRows(old: [String], new: [String]) -> [RawRow] {
        let diff = new.difference(from: old)
        var removalIndices = Set<Int>()
        var insertionIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removalIndices.insert(offset)
            case .insert(let offset, _, _):
                insertionIndices.insert(offset)
            }
        }

        var rows: [RawRow] = []
        rows.reserveCapacity(max(old.count, new.count))
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < old.count || newIdx < new.count {
            if oldIdx < old.count, removalIndices.contains(oldIdx) {
                rows.append(.removed(text: old[oldIdx], oldLine: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < new.count, insertionIndices.contains(newIdx) {
                rows.append(.added(text: new[newIdx], newLine: newIdx + 1))
                newIdx += 1
            } else if oldIdx < old.count, newIdx < new.count {
                rows.append(.context(text: new[newIdx], oldLine: oldIdx + 1, newLine: newIdx + 1))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < old.count {
                rows.append(.removed(text: old[oldIdx], oldLine: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < new.count {
                rows.append(.added(text: new[newIdx], newLine: newIdx + 1))
                newIdx += 1
            }
        }
        return rows
    }

    private static func buildTrimmedWindowRows(old: [String], new: [String]) -> [RawRow] {
        var prefixLen = 0
        let minCount = min(old.count, new.count)
        while prefixLen < minCount, old[prefixLen] == new[prefixLen] {
            prefixLen += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefixLen, newEnd > prefixLen, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        var rows: [RawRow] = []
        rows.reserveCapacity(old.count + (newEnd - prefixLen))
        for idx in 0..<prefixLen {
            rows.append(.context(text: old[idx], oldLine: idx + 1, newLine: idx + 1))
        }
        for idx in prefixLen..<oldEnd {
            rows.append(.removed(text: old[idx], oldLine: idx + 1))
        }
        for idx in prefixLen..<newEnd {
            rows.append(.added(text: new[idx], newLine: idx + 1))
        }
        let suffixCount = old.count - oldEnd
        for offset in 0..<suffixCount {
            rows.append(.context(
                text: old[oldEnd + offset],
                oldLine: oldEnd + offset + 1,
                newLine: newEnd + offset + 1
            ))
        }
        return rows
    }

    private static func changeWindows(rows: [RawRow], radius: Int) -> [Range<Int>] {
        var windows: [Range<Int>] = []
        for (idx, row) in rows.enumerated() where row.isChange {
            let low = max(0, idx - radius)
            let high = min(rows.count, idx + radius + 1)
            if let last = windows.last, low <= last.upperBound {
                windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, high)
            } else {
                windows.append(low..<high)
            }
        }
        return windows
    }

    private static func buildAnchoredEditHunks(rows: [RawRow], anchorLines: Int) -> [PreviewFile.EditHunk] {
        let windows = changeWindows(rows: rows, radius: anchorLines)
        return windows.compactMap { window in
            var oldSlice: [String] = []
            var newSlice: [String] = []
            for row in rows[window] {
                switch row {
                case .context(let text, _, _):
                    oldSlice.append(text)
                    newSlice.append(text)
                case .removed(let text, _):
                    oldSlice.append(text)
                case .added(let text, _):
                    newSlice.append(text)
                }
            }
            let oldText = oldSlice.joined(separator: "\n")
            let newText = newSlice.joined(separator: "\n")
            guard oldText != newText else { return nil }
            return PreviewFile.EditHunk(oldString: oldText, newString: newText)
        }
    }

    private static func formatUnifiedDiff(
        rows: [RawRow],
        contextLines: Int,
        maxLines: Int
    ) -> String {
        let windows = changeWindows(rows: rows, radius: contextLines)
        guard !windows.isEmpty else { return "" }

        var output: [String] = []
        var truncated = false

        outer: for window in windows {
            var oldStart: Int?
            var newStart: Int?
            var oldCount = 0
            var newCount = 0

            for row in rows[window] {
                switch row {
                case .context(_, let o, let n):
                    if oldStart == nil { oldStart = o }
                    if newStart == nil { newStart = n }
                    oldCount += 1
                    newCount += 1
                case .removed(_, let o):
                    if oldStart == nil { oldStart = o }
                    oldCount += 1
                case .added(_, let n):
                    if newStart == nil { newStart = n }
                    newCount += 1
                }
            }

            let resolvedOldStart = oldStart ?? (oldCount == 0 ? 0 : 1)
            let resolvedNewStart = newStart ?? (newCount == 0 ? 0 : 1)
            output.append("@@ -\(resolvedOldStart),\(oldCount) +\(resolvedNewStart),\(newCount) @@")
            if output.count >= maxLines {
                truncated = true
                break outer
            }

            for row in rows[window] {
                switch row {
                case .context(let text, _, _):
                    output.append(" \(text)")
                case .removed(let text, _):
                    output.append("-\(text)")
                case .added(let text, _):
                    output.append("+\(text)")
                }
                if output.count >= maxLines {
                    truncated = true
                    break outer
                }
            }
        }

        if truncated {
            output.append("…")
        }
        return output.joined(separator: "\n")
    }
}
