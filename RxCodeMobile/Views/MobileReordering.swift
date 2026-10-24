import CoreTransferable
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

private struct MobileTaskDragItem: Identifiable, Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

extension DynamicViewContent {
    @ViewBuilder
    func mobileReorderable() -> some View {
        if #available(iOS 27.0, *) { reorderable() } else { self }
    }

    @ViewBuilder
    func mobileReorderable(collectionID: some Hashable & Sendable) -> some View {
        if #available(iOS 27.0, *) { reorderable(collectionID: collectionID) } else { self }
    }
}

extension View {
    @ViewBuilder
    func mobileTaskReorderContainer(
        status: TaskStatus,
        move: @escaping ([UUID], UUID?, TaskStatus) -> Void
    ) -> some View {
        if #available(iOS 27.0, *) {
            // Each column owns its card insertion placeholders. Transfer only
            // IDs when crossing into another column's container.
            reorderContainer(for: ProjectTask.self) { difference in
                switch difference.destination.position {
                case .before(let id): move(difference.sources, id, status)
                case .end: move(difference.sources, nil, status)
                }
            }
            .dragContainer(for: MobileTaskDragItem.self) { (ids: [UUID]) in
                ids.map { MobileTaskDragItem(id: $0) }
            }
            .dropDestination(for: MobileTaskDragItem.self) { items, session in
                guard !items.isEmpty else { return }
                let target: UUID?
                switch session.reorderDestination(for: ProjectTask.self)?.position {
                case .before(let id): target = id
                case .end, nil: target = nil
                }
                move(items.map(\.id), target, status)
            }
        } else { self }
    }

    /// A fixed layout root keeps conditional modifiers and presentations in
    /// a row from changing the identity SwiftUI uses for its drag payload.
    func mobileReorderItem() -> some View {
        VStack(spacing: 0) { self }
    }

    @ViewBuilder
    func mobileReorderContainer<Item: Identifiable>(
        for item: Item.Type,
        move: @escaping ([Item.ID], Item.ID?) -> Void
    ) -> some View where Item.ID: Sendable {
        if #available(iOS 27.0, *) {
            reorderContainer(for: item) { difference in
                switch difference.destination.position {
                case .before(let id): move(difference.sources, id)
                case .end: move(difference.sources, nil)
                }
            }
        } else { self }
    }

    @ViewBuilder
    func mobileReorderContainer<Item: Identifiable, CollectionID: Hashable & Sendable>(
        for item: Item.Type,
        in collection: CollectionID.Type,
        move: @escaping ([Item.ID], Item.ID?, CollectionID) -> Void
    ) -> some View where Item.ID: Sendable {
        if #available(iOS 27.0, *) {
            reorderContainer(for: item, in: collection) { difference in
                switch difference.destination.position {
                case .before(let id): move(difference.sources, id, difference.destination.collectionID)
                case .end: move(difference.sources, nil, difference.destination.collectionID)
                }
            }
        } else { self }
    }

    // Older systems keep their existing drag/drop interaction. On iOS 27,
    // SwiftUI owns the gesture and animates the insertion placeholder.
    @ViewBuilder
    func mobileLegacyDrag(_ payload: String) -> some View {
        if #available(iOS 27.0, *) { self } else { draggable(payload) }
    }

    @ViewBuilder
    func mobileLegacyDrop(_ action: @escaping ([String], CGPoint) -> Bool) -> some View {
        if #available(iOS 27.0, *) { self } else { dropDestination(for: String.self, action: action) }
    }
}

/// Resolve the system's stable IDs against the latest collection, including
/// items hidden by a filter. A missing destination means a stale drop.
func mobileReordered<Item: Identifiable>(
    _ items: [Item], moving sources: [Item.ID], before target: Item.ID?
) -> [Item]? {
    let sourceIDs = Set(sources)
    let moving = sources.compactMap { id in items.first { $0.id == id } }
    guard !moving.isEmpty, moving.count == sourceIDs.count,
          target.map({ !sourceIDs.contains($0) }) ?? true else { return nil }
    var result = items.filter { !sourceIDs.contains($0.id) }
    let index: Int
    if let target {
        guard let destination = result.firstIndex(where: { $0.id == target }) else { return nil }
        index = destination
    } else { index = result.endIndex }
    result.insert(contentsOf: moving, at: index)
    return result.map(\.id) == items.map(\.id) ? nil : result
}
