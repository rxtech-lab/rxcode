import Foundation
import SwiftData
import RxCodeCore

// MARK: - Thread File Edits & Detected Shell Changes

@MainActor
extension ThreadStore {

    // MARK: - Thread File Edits

    func fetchFileEdits(sessionId: String) -> [ThreadFileEdit] {
        let descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.firstEditedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Number of distinct files this session recorded edits to. There is one row
    /// per `(sessionId, path)`, so a row count equals the distinct-file count —
    /// a cheap query (no content loaded) used to gate the "Commit Files" action.
    func fileEditCount(sessionId: String) -> Int {
        let descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Every session id that recorded at least one file edit, in a single query.
    func sessionIdsWithFileEdits() -> Set<String> {
        var descriptor = FetchDescriptor<ThreadFileEdit>()
        descriptor.propertiesToFetch = [\ThreadFileEdit.sessionId]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.sessionId))
    }

    /// Edited-file count for every session, in a single query.
    func fileEditCountsBySession() -> [String: Int] {
        var descriptor = FetchDescriptor<ThreadFileEdit>()
        descriptor.propertiesToFetch = [\ThreadFileEdit.sessionId]
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(into: [:]) { result, row in
            result[row.sessionId, default: 0] += 1
        }
    }

    private func fetchFileEdit(sessionId: String, path: String) -> ThreadFileEdit? {
        var descriptor = FetchDescriptor<ThreadFileEdit>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.path == path }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Append edit hunks to the file's row for this session, creating the row if it
    /// does not yet exist. Hunks are aggregated across turns; `containsWrite` becomes
    /// sticky once any Write or file-creation step contributes.
    ///
    /// When `stepBeforeContent` is supplied and differs from the previously recorded
    /// `modifiedContent`, another thread or external editor modified the file in
    /// between turns, so `hasExternalInterleaving` is marked true to isolate hunks.
    func appendFileEdit(
        sessionId: String,
        path: String,
        hunks: [PreviewFile.EditHunk],
        containsWrite: Bool,
        originalContent: String? = nil,
        modifiedContent: String? = nil,
        stepBeforeContent: String? = nil,
        isDeleted: Bool = false,
        isAmbiguous: Bool = false
    ) {
        guard !hunks.isEmpty || isDeleted else { return }
        let name = (path as NSString).lastPathComponent
        if let existing = fetchFileEdit(sessionId: sessionId, path: path) {
            if let prevModified = existing.modifiedContent,
               let stepBeforeContent,
               prevModified != stepBeforeContent {
                existing.hasExternalInterleaving = true
            }
            existing.append(hunks: hunks, containsWrite: containsWrite)
            existing.name = name
            if existing.originalContent == nil, let originalContent {
                existing.originalContent = originalContent
            }
            existing.modifiedContent = modifiedContent
            existing.isDeleted = isDeleted
            if isAmbiguous {
                existing.isAmbiguous = true
            }
        } else {
            context.insert(ThreadFileEdit(
                sessionId: sessionId,
                path: path,
                name: name,
                hunks: hunks,
                containsWrite: containsWrite,
                originalContent: originalContent,
                modifiedContent: modifiedContent,
                hasExternalInterleaving: nil,
                isDeleted: isDeleted ? true : nil,
                isAmbiguous: isAmbiguous ? true : nil
            ))
        }
        save()
    }

    func renameFileEdits(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        let rows = fetchFileEdits(sessionId: oldId)
        for row in rows {
            if let existing = fetchFileEdit(sessionId: newId, path: row.path) {
                existing.append(hunks: row.hunks, containsWrite: row.containsWrite)
                if existing.originalContent == nil {
                    existing.originalContent = row.originalContent
                }
                if row.modifiedContent != nil {
                    existing.modifiedContent = row.modifiedContent
                }
                if row.hasExternalInterleaving == true {
                    existing.hasExternalInterleaving = true
                }
                existing.isDeleted = row.isDeleted
                if row.isAmbiguous == true {
                    existing.isAmbiguous = true
                }
                context.delete(row)
            } else {
                row.sessionId = newId
            }
        }
    }

    func deleteFileEdits(sessionId: String) {
        deleteFileEditRows(sessionId: sessionId)
        save()
    }

    func deleteFileEditRows(sessionId: String) {
        for row in fetchFileEdits(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Per-Tool Detected Shell Changes (CLI Reload Sidecar)

    private func fetchDetectedToolChange(sessionId: String, toolCallId: String) -> ToolDetectedChangeRecord? {
        var descriptor = FetchDescriptor<ToolDetectedChangeRecord>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.toolCallId == toolCallId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func upsertDetectedToolChanges(
        sessionId: String,
        toolCallId: String,
        changes: [DetectedShellFileChange]
    ) {
        guard !changes.isEmpty else { return }
        if let existing = fetchDetectedToolChange(sessionId: sessionId, toolCallId: toolCallId) {
            existing.changes = changes
        } else {
            context.insert(ToolDetectedChangeRecord(
                sessionId: sessionId,
                toolCallId: toolCallId,
                changes: changes
            ))
        }
        save()
    }

    func loadDetectedToolChanges(sessionId: String) -> [String: [DetectedShellFileChange]] {
        let descriptor = FetchDescriptor<ToolDetectedChangeRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var map: [String: [DetectedShellFileChange]] = [:]
        for row in rows {
            let decoded = row.changes
            if !decoded.isEmpty {
                map[row.toolCallId] = decoded
            }
        }
        return map
    }

    func renameDetectedToolChanges(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        let descriptor = FetchDescriptor<ToolDetectedChangeRecord>(
            predicate: #Predicate { $0.sessionId == oldId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows {
            if let existing = fetchDetectedToolChange(sessionId: newId, toolCallId: row.toolCallId) {
                existing.changes = row.changes
                context.delete(row)
            } else {
                row.sessionId = newId
            }
        }
    }

    func deleteDetectedToolChangeRows(sessionId: String) {
        let descriptor = FetchDescriptor<ToolDetectedChangeRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows { context.delete(row) }
    }
}
