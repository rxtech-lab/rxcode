import Foundation

/// Saved views are account preferences. Story filters travel as cloud IDs,
/// because each device assigns its own local story UUIDs.
public struct CloudSavedView: Codable, Sendable, Hashable, Identifiable {
    public var view: TaskSavedView
    public var storyRemoteIDs: [String]
    public var id: UUID { view.id }

    public init(view: TaskSavedView, sync: CloudBoardSyncState) {
        self.view = view
        storyRemoteIDs = view.storyIds.map { sync.storyRemoteId($0) ?? $0.uuidString }
        self.view.storyIds = []
        self.view.filterSnapshot?.tasks = view.filterSnapshot?.tasks.compactMap { UUID(uuidString: $0).flatMap { sync.taskRemoteId($0) } } ?? []
        self.view.filterSnapshot?.stories = view.filterSnapshot?.stories.compactMap { UUID(uuidString: $0).flatMap { sync.storyRemoteId($0) } } ?? []
    }

    public func localView(sync: CloudBoardSyncState) -> TaskSavedView {
        var result = view
        // Missing stories must retain a restrictive filter instead of matching all.
        result.storyIds = storyRemoteIDs.map {
            sync.localStoryId(forRemote: $0) ?? UUID(uuidString: $0) ?? view.id
        }
        result.filterSnapshot?.tasks = view.filterSnapshot?.tasks.compactMap { sync.localTaskId(forRemote: $0)?.uuidString } ?? []
        result.filterSnapshot?.stories = view.filterSnapshot?.stories.compactMap { sync.localStoryId(forRemote: $0)?.uuidString } ?? []
        return result
    }
}

public struct CloudSavedViews: Codable, Sendable, Equatable {
    public var views: [CloudSavedView]
    public var revision: Int

    public init(views: [CloudSavedView] = [], revision: Int = 0) {
        self.views = views
        self.revision = revision
    }

    /// Mobile may edit standard views; Swift-filter views remain host-owned.
    public static func preservingRemoteScripts(
        in views: [CloudSavedView], remote: [CloudSavedView]
    ) -> [CloudSavedView] {
        let scripts = Dictionary(remote.map { ($0.id, $0.view) }, uniquingKeysWith: { first, _ in first })
        let preserved = remote.filter { entry in entry.view.hasFilterScript && !views.contains(where: { $0.id == entry.id }) }
        return (views + preserved).map { entry in
            var result = entry
            if var remote = remote.first(where: { $0.id == entry.id }), remote.view.hasFilterScript {
                // Choosing a standard default view may clear the previous default marker.
                remote.view.isDefault = remote.view.isDefault && entry.view.isDefault
                remote.view.isHidden = entry.view.isHidden
                return remote
            }
            result.view.filterScript = scripts[entry.id]?.filterScript
            return result
        }
    }

    /// Merge independent tab edits and deletions. A same-tab conflict favors
    /// the pending local edit; compare-and-swap prevents overwriting a newer fetch.
    public static func merging(local: [CloudSavedView], base: [CloudSavedView]?, remote: [CloudSavedView]) -> [CloudSavedView] {
        let base = base ?? []
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localOrderChanged = local.map(\.id) != base.map(\.id)
        let order = localOrderChanged ? local + remote : remote + local
        var seen = Set<UUID>()
        var merged: [CloudSavedView] = []
        for item in order where seen.insert(item.id).inserted {
            let local = localByID[item.id]
            let old = baseByID[item.id]
            let remote = remoteByID[item.id]
            if local != old {
                if let local { merged.append(local) }
            } else if let remote {
                merged.append(remote)
            }
        }
        // At most one default survives concurrent edits on different tabs.
        let preferredDefault = local.first { $0.view.isDefault && $0 != baseByID[$0.id] }?.id
            ?? merged.first { $0.view.isDefault }?.id
        for index in merged.indices {
            merged[index].view.isDefault = merged[index].id == preferredDefault
        }
        return merged
    }
}
