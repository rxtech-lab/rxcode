import Foundation

public extension TaskBoard {
    /// Projects cloud rows into the same board model used by desktop and mobile.
    /// Retains local identities across refreshes, so navigation and parent links stay valid.
    func replacingCloudRows(_ remote: CloudRemoteBoard, projectID: UUID) -> TaskBoard {
        var board = self
        var sync = cloudSync ?? CloudBoardSyncState()
        sync.members = remote.members
        sync.role = remote.role
        sync.currentUserId = remote.currentUserId
        let storyIDs = Set(remote.stories.map(\.id))
        let taskIDs = Set(remote.tasks.map(\.id))
        sync.stories = sync.stories.filter { storyIDs.contains($0.value.remoteId) }
        sync.tasks = sync.tasks.filter { taskIDs.contains($0.value.remoteId) }
        for row in remote.stories {
            let id = sync.localStoryId(forRemote: row.id) ?? UUID()
            sync.stories[id] = CloudItemLink(remoteId: row.id, base: row.fields)
        }
        for row in remote.tasks {
            let id = sync.localTaskId(forRemote: row.id) ?? UUID()
            sync.tasks[id] = CloudItemLink(remoteId: row.id, base: row.fields)
        }
        let typeNames = remote.stories.compactMap { $0.fields.type } + remote.tasks.compactMap { $0.fields.type }
        for name in typeNames where board.itemTypeId(named: name) == nil {
            if board.itemTypes.isEmpty { board.itemTypes = board.effectiveTypes }
            board.itemTypes.append(TaskItemType(name: name))
        }
        // Delay authors and reviewers resolve against the fresh member list.
        board.cloudSync = sync
        board.stories = remote.stories.map { row in
            let id = sync.localStoryId(forRemote: row.id)!
            let existing = stories.first { $0.id == id } ?? ProjectStory(id: id, projectId: projectID, title: row.fields.title)
            var card = board.applying(row.fields, to: existing, updatedAt: row.updatedAt)
            card.assigneeProfiles = (remote.members ?? []).filter { card.assigneeIds.contains($0.userId) }
            return card
        }
        board.tasks = remote.tasks.map { row in
            let id = sync.localTaskId(forRemote: row.id)!
            let existing = tasks.first { $0.id == id } ?? ProjectTask(id: id, projectId: projectID, title: row.fields.title)
            var card = board.applying(row.fields, to: existing, sync: sync, updatedAt: row.updatedAt)
            card.assigneeProfiles = (remote.members ?? []).filter { card.assigneeIds.contains($0.userId) }
            return card
        }
        board.cloudSync = sync
        return board
    }
}
