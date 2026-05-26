import Foundation
import RxCodeChatKit
import RxCodeCore
import RxCodeSync

// MARK: - Mobile File Diff & Snapshot Budget Helpers

extension AppState {
    /// Strips per-file `originalContent` / `modifiedContent` once the running
    /// total of attached snapshots would push the encoded reply past the
    /// relay's 10 MiB envelope cap. Order is preserved so earlier files in the
    /// thread keep their snapshot-pair diff; later files fall back to the
    /// `fullFileDiff` already attached on each `SyncFileEdit`.
    nonisolated static func applySnapshotBudget(to edits: [SyncFileEdit]) -> [SyncFileEdit] {
        // Conservative budget — leaves headroom for hunks, full-file diffs,
        // uncommitted git changes, JSON escaping, and base64 envelope overhead.
        let totalBudget = 4 * 1024 * 1024
        let perFileCap = 512 * 1024
        var remaining = totalBudget
        return edits.map { edit in
            let pairSize = (edit.originalContent?.utf8.count ?? 0)
                + (edit.modifiedContent?.utf8.count ?? 0)
            guard pairSize > 0, pairSize <= perFileCap, pairSize <= remaining else {
                return SyncFileEdit(
                    path: edit.path,
                    name: edit.name,
                    containsWrite: edit.containsWrite,
                    hunks: edit.hunks,
                    fullFileDiff: edit.fullFileDiff,
                    originalContent: nil,
                    modifiedContent: nil
                )
            }
            remaining -= pairSize
            return edit
        }
    }

    nonisolated static func mobileFullFileDiff(
        path: String,
        hunks: [PreviewFile.EditHunk],
        originalContent: String?
    ) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let currentContent = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            if let originalContent {
                return snapshotDiff(original: originalContent, current: currentContent)
            }
            return fullFileDiff(currentContent: currentContent, hunks: hunks)
        }.value
    }

    nonisolated static func fullFileDiff(currentContent: String, hunks: [PreviewFile.EditHunk]) -> String {
        currentContentDiff(currentContent: currentContent, hunks: hunks)
    }

    /// Build a unified diff string from a pre-edit snapshot and the file's
    /// current content. Mirrors `FileDiffView.buildSnapshotDiffLines` on
    /// macOS but emits the wire-format string the mobile renderer parses.
    nonisolated static func snapshotDiff(original: String, current: String) -> String {
        let oldLines = contentLines(original)
        let newLines = contentLines(current)
        let diff = newLines.difference(from: oldLines)
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

        var lines: [String] = []
        var oldIdx = 0
        var newIdx = 0
        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count, removalIndices.contains(oldIdx) {
                lines.append("-\(oldLines[oldIdx])")
                oldIdx += 1
            } else if newIdx < newLines.count, let added = insertionElements[newIdx] {
                lines.append("+\(added)")
                newIdx += 1
            } else if oldIdx < oldLines.count, newIdx < newLines.count {
                lines.append(" \(newLines[newIdx])")
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < oldLines.count {
                lines.append(" \(oldLines[oldIdx])")
                oldIdx += 1
            } else if newIdx < newLines.count {
                lines.append(" \(newLines[newIdx])")
                newIdx += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func currentContentDiff(
        currentContent: String,
        hunks: [PreviewFile.EditHunk]
    ) -> String {
        var lines = contentLines(currentContent).map { " \($0)" }
        guard !lines.isEmpty else {
            return hunks.flatMap { hunk in
                contentLines(hunk.oldString).map { "-\($0)" } + contentLines(hunk.newString).map { "+\($0)" }
            }.joined(separator: "\n")
        }

        for hunk in hunks {
            let addedLines = contentLines(hunk.newString)
            guard !addedLines.isEmpty else { continue }
            let matchStart = firstRange(of: addedLines, in: lines.map(contentWithoutDiffMarker))
            guard let matchStart else { continue }

            let removedLines = contentLines(hunk.oldString)
            if !removedLines.isEmpty {
                lines.insert(contentsOf: removedLines.map { "-\($0)" }, at: matchStart)
            }

            let addedStart = matchStart + removedLines.count
            for offset in addedLines.indices where addedStart + offset < lines.count {
                lines[addedStart + offset] = "+\(addedLines[offset])"
            }
        }

        return lines.joined(separator: "\n")
    }

    nonisolated static func firstRange(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
        }
        return nil
    }

    nonisolated static func contentWithoutDiffMarker(_ text: String) -> String {
        guard let first = text.first, first == " " || first == "+" || first == "-" else {
            return text
        }
        return String(text.dropFirst())
    }

    nonisolated static func contentLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

// MARK: - Remote File Preview

enum MobileRemoteFileReadError: LocalizedError {
    case unreadable
    case binary

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "File could not be opened."
        case .binary:
            return "Binary file — preview not available."
        }
    }
}

extension AppState {
    nonisolated static func isPath(_ path: String, underAnyProject projectPaths: [String]) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return projectPaths.contains { projectPath in
            let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
            return standardizedPath == root || standardizedPath.hasPrefix(root + "/")
        }
    }

    nonisolated static func readMobilePreviewFile(path: String) throws -> (content: String, truncated: Bool) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? Int) ?? 0
        let byteLimit = 1_500_000
        let truncated = size > byteLimit

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            throw MobileRemoteFileReadError.unreadable
        }
        defer { try? handle.close() }

        let data = try handle.read(upToCount: min(size, byteLimit)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else {
            throw MobileRemoteFileReadError.binary
        }
        return (content, truncated)
    }
}
