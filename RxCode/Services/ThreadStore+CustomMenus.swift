import Foundation
import SwiftData
import RxCodeCore

/// Persistence for user-defined custom context-menu items. The desktop is the
/// single source of truth; `CustomMenuHook` reads these to build menu items and
/// the Settings tab mutates them.
extension ThreadStore {
    /// All custom menu items, ordered for display (sortOrder, then creation).
    func allCustomMenuItems() -> [CustomMenuItemRecord] {
        let descriptor = FetchDescriptor<CustomMenuItemRecord>(
            sortBy: [
                SortDescriptor(\.sortOrder, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Enabled items that should appear on `surface` for `projectId` — i.e. items
    /// scoped to that project plus the "all projects" (nil) items.
    func customMenuItems(projectId: UUID?, surface: CustomMenuItemRecord.Surface) -> [CustomMenuItemRecord] {
        // Surface membership lives in the computed `surfaces` list, so it can't be
        // expressed in a #Predicate — fetch the enabled rows and filter in Swift.
        let descriptor = FetchDescriptor<CustomMenuItemRecord>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [
                SortDescriptor(\.sortOrder, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.filter {
            ($0.projectId == nil || $0.projectId == projectId) && $0.surfaces.contains(surface)
        }
    }

    func fetchCustomMenuItem(id: String) -> CustomMenuItemRecord? {
        let descriptor = FetchDescriptor<CustomMenuItemRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Insert a new record or update the existing one in place.
    func upsertCustomMenuItem(_ record: CustomMenuItemRecord) {
        if let existing = fetchCustomMenuItem(id: record.id) {
            existing.title = record.title
            existing.systemImage = record.systemImage
            existing.projectId = record.projectId
            existing.surface = record.surface
            existing.actionKind = record.actionKind
            existing.httpMethod = record.httpMethod
            existing.urlString = record.urlString
            existing.headersJSON = record.headersJSON
            existing.bodyTemplate = record.bodyTemplate
            existing.messageTemplate = record.messageTemplate
            existing.targetSessionId = record.targetSessionId
            existing.conditionType = record.conditionType
            existing.conditionScript = record.conditionScript
            existing.conditionCompiled = record.conditionCompiled
            existing.isEnabled = record.isEnabled
            existing.sortOrder = record.sortOrder
            existing.updatedAt = .now
        } else {
            context.insert(record)
        }
        save()
    }

    func deleteCustomMenuItem(id: String) {
        guard let row = fetchCustomMenuItem(id: id) else { return }
        context.delete(row)
        save()
    }
}
