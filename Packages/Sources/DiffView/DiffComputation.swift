import Foundation
import RxCodeCore

/// Pure, non-isolated diff builders. Lifted out of the macOS-only
/// `FileDiffView` so mobile and any other surface can share the exact same
/// computation pipeline.
public enum DiffComputation {

    // MARK: - Hunks → DiffLine

    /// Renders a series of old/new replacement hunks as a removed-then-added
    /// block. Multiple hunks get a separator header. Common leading indentation
    /// is stripped so the diff doesn't visually shift right.
    ///
    /// A hunk with empty `oldString` (file creation) renders as all-green `+`
    /// lines numbered from 1 — no spurious empty `-` row. A hunk with empty
    /// `newString` (file deletion) renders as all-red `-` lines numbered from
    /// 1 — no spurious empty `+` row. This keeps the rendered diff in sync
    /// with the sidebar's "+N" / "-N" counts.
    public nonisolated static func buildEditDiffLines(from hunks: [PreviewFile.EditHunk]) -> [DiffLine] {
        var lines: [DiffLine] = []
        // Pure-create / pure-delete numbering is cumulative across hunks so a
        // multi-hunk file creation still numbers from 1 → N across the file.
        var createNumber = 1
        var deleteNumber = 1
        for (index, hunk) in hunks.enumerated() {
            if hunks.count > 1 {
                lines.append(DiffLine(text: "@@ edit \(index + 1) of \(hunks.count) @@", kind: .hunk))
            }
            let oldLines = contentLines(hunk.oldString)
            let newLines = contentLines(hunk.newString)
            let (trimmedOld, trimmedNew) = stripCommonIndent(old: oldLines, new: newLines)

            let isPureCreate = oldLines.isEmpty && !newLines.isEmpty
            let isPureDelete = !oldLines.isEmpty && newLines.isEmpty

            for text in trimmedOld {
                let number = isPureDelete ? deleteNumber : nil
                lines.append(DiffLine(
                    text: "-" + text,
                    kind: .removed,
                    oldLineNumber: number,
                    newLineNumber: nil
                ))
                if isPureDelete { deleteNumber += 1 }
            }
            for text in trimmedNew {
                let number = isPureCreate ? createNumber : nil
                lines.append(DiffLine(
                    text: "+" + text,
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: number
                ))
                if isPureCreate { createNumber += 1 }
            }
        }
        return lines
    }

    // MARK: - Snapshot ↔ current → DiffLine

    /// Exact unified diff between two full-file snapshots — used when a
    /// pre-edit snapshot is available so we never reverse-apply hunks. Both
    /// gutter columns get accurate line numbers.
    public nonisolated static func buildSnapshotDiffLines(original: String, current: String) -> [DiffLine] {
        let originalLines = contentLines(original)
        let currentLines = contentLines(current)
        return computeUnifiedDiffLines(old: originalLines, new: currentLines)
    }

    // MARK: - Thread edit: snapshot pair with hunk fallback

    /// Picks the best in-memory diff for a thread-edited file using only the
    /// snapshots and hunks the thread already recorded. Prefers the exact
    /// snapshot-pair diff (`buildSnapshotDiffLines`). When that pair collapses
    /// — e.g. the pre-edit snapshot was captured *after* the edit applied so
    /// `originalContent == modifiedContent` — falls back to rendering the
    /// recorded hunks via `buildEditDiffLines`, so real edits never silently
    /// vanish into a "No changes" body when the sidebar is reporting non-zero
    /// `+N/-N` from the same hunks.
    public nonisolated static func buildThreadEditDiff(
        originalContent: String?,
        modifiedContent: String?,
        hunks: [PreviewFile.EditHunk]
    ) -> [DiffLine] {
        if let modifiedContent {
            let snapshotLines = buildSnapshotDiffLines(
                original: originalContent ?? "",
                current: modifiedContent
            )
            // A collapsed snapshot pair (original == modified) still produces
            // a full list of context lines — that's "no real change", so
            // require at least one +/- line before trusting the snapshot diff.
            let hasRealChange = snapshotLines.contains { $0.kind == .added || $0.kind == .removed }
            if hasRealChange {
                return snapshotLines
            }
        }
        return buildEditDiffLines(from: hunks)
    }

    // MARK: - Hunks reverse-applied to current → DiffLine

    /// Renders the full current file with the supplied hunks highlighted as
    /// edits on top of it. Works by reverse-applying each hunk's `newString` →
    /// `oldString` against the current content to reconstruct the pre-edit
    /// state, then running a line diff against the current lines. Hunks that
    /// can't be reverse-applied (pure deletions or hunks whose `newString` is
    /// no longer present) become "orphan" hunks rendered at the top with a
    /// header so the change still shows up.
    public nonisolated static func buildFullFileEditDiffLines(
        currentContent: String,
        hunks: [PreviewFile.EditHunk]
    ) -> [DiffLine] {
        let currentLines = contentLines(currentContent)
        guard !currentLines.isEmpty else {
            return buildEditDiffLines(from: hunks)
        }

        var reconstructed = currentContent
        var orphans: [PreviewFile.EditHunk] = []

        for hunk in hunks.reversed() {
            if hunk.newString.isEmpty {
                if !hunk.oldString.isEmpty {
                    orphans.insert(hunk, at: 0)
                }
                continue
            }
            if let range = reconstructed.range(of: hunk.newString) {
                reconstructed.replaceSubrange(range, with: hunk.oldString)
            } else if !hunk.oldString.isEmpty {
                orphans.insert(hunk, at: 0)
            }
        }

        let preEditLines = contentLines(reconstructed)
        let unifiedLines = computeUnifiedDiffLines(old: preEditLines, new: currentLines)

        guard !orphans.isEmpty else { return unifiedLines }

        var result: [DiffLine] = []
        for (idx, orphan) in orphans.enumerated() {
            let header = orphans.count > 1
                ? "@@ unmatched change \(idx + 1)/\(orphans.count) @@"
                : "@@ unmatched change @@"
            result.append(DiffLine(text: header, kind: .hunk))
            for line in contentLines(orphan.oldString) {
                result.append(DiffLine(text: "-\(line)", kind: .removed))
            }
            for line in contentLines(orphan.newString) {
                result.append(DiffLine(text: "+\(line)", kind: .added))
            }
        }
        result.append(contentsOf: unifiedLines)
        return result
    }

    // MARK: - Unified diff text → DiffLine

    /// Parses raw unified-diff text (`git diff` output) into `DiffLine`s with
    /// gutter line numbers reconstructed from `@@ ... @@` hunk headers.
    public nonisolated static func parseUnifiedDiff(_ raw: String) -> [DiffLine] {
        guard !raw.isEmpty else { return [] }
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var oldLine = 0
        var newLine = 0
        var result: [DiffLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) {
                    oldLine = o
                    newLine = n
                }
                result.append(DiffLine(text: line, kind: .hunk))
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                result.append(DiffLine(text: line, kind: .meta))
            } else if line.hasPrefix("+") {
                result.append(DiffLine(text: line, kind: .added, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                result.append(DiffLine(text: line, kind: .removed, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else {
                result.append(DiffLine(text: line, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return result
    }

    // MARK: - Helpers

    private nonisolated static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@") != nil,
              scanner.scanString(" -") != nil,
              let oldStart = scanner.scanInt() else { return nil }
        _ = scanner.scanString(",")
        _ = scanner.scanInt()
        guard scanner.scanString(" +") != nil,
              let newStart = scanner.scanInt() else { return nil }
        return (oldStart, newStart)
    }

    private nonisolated static func computeUnifiedDiffLines(old: [String], new: [String]) -> [DiffLine] {
        let diff = new.difference(from: old)
        var removalIndices = Set<Int>()
        var insertionElements: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removalIndices.insert(offset)
            case .insert(let offset, let element, _):
                insertionElements[offset] = element
            }
        }

        var lines: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < old.count || newIdx < new.count {
            if oldIdx < old.count, removalIndices.contains(oldIdx) {
                lines.append(DiffLine(
                    text: "-\(old[oldIdx])",
                    kind: .removed,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: nil
                ))
                oldIdx += 1
            } else if newIdx < new.count, let added = insertionElements[newIdx] {
                lines.append(DiffLine(
                    text: "+\(added)",
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: newIdx + 1
                ))
                newIdx += 1
            } else if oldIdx < old.count, newIdx < new.count {
                lines.append(DiffLine(
                    text: " \(new[newIdx])",
                    kind: .context,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: newIdx + 1
                ))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < old.count {
                lines.append(DiffLine(
                    text: " \(old[oldIdx])",
                    kind: .context,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: nil
                ))
                oldIdx += 1
            } else if newIdx < new.count {
                lines.append(DiffLine(
                    text: " \(new[newIdx])",
                    kind: .context,
                    oldLineNumber: nil,
                    newLineNumber: newIdx + 1
                ))
                newIdx += 1
            }
        }

        return lines
    }

    private nonisolated static func contentLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private nonisolated static func stripCommonIndent(old: [String], new: [String]) -> (old: [String], new: [String]) {
        let combined = old + new
        let commonIndent = combined
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
            .min() ?? 0
        guard commonIndent > 0 else { return (old, new) }
        func strip(_ line: String) -> String {
            line.count >= commonIndent ? String(line.dropFirst(commonIndent)) : line
        }
        return (old.map(strip), new.map(strip))
    }
}
