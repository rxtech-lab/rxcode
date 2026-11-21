import Foundation
import RxAuthSwift
import RxCodeCore

extension AppState {
    /// Inserts or replaces a story, and carries its shared fields to the copies
    /// on every linked project's board.
    ///
    /// The link list is owned by `linkStory` / `unlinkStory`: an edit keeps the
    /// stored links, so a form or an older mobile client that doesn't know
    /// about links can't drop them.
    func upsertStory(_ story: ProjectStory, defaultAssignee: Bool = true) {
        guard taskBoard(for: story.projectId).story(id: story.id) == nil || canEditCard(story) else { return }
        var stamped = story
        if defaultAssignee, taskBoard(for: story.projectId).story(id: story.id) == nil,
           stamped.assigneeIds.isEmpty, let userID = rxAuth.user?.id {
            stamped.assigneeIds = [userID]
            stamped.assigneeProfiles = [CardAssignee(userId: userID, name: rxAuth.user?.name, email: rxAuth.user?.email, image: rxAuth.user?.image)]
        }
        stamped.delays = stamped.delays.stampingAuthors(cardActor)
        stamped.updatedAt = Date()
        if let stored = taskBoard(for: story.projectId).story(id: story.id) {
            stamped.linkedProjectIds = stored.linkedProjectIds
        }
        writeStoryCopies(stamped, group: stamped.projectGroup)
    }

    /// Saves a story edited in a form, applying any change to its project
    /// links. `upsertStory` keeps stored links, so the difference is applied
    /// here through `linkStory` / `unlinkStory`. A new story's links are
    /// written by `upsertStory` directly.
    func saveStory(_ story: ProjectStory, defaultAssignee: Bool = true) async {
        guard taskBoard(for: story.projectId).story(id: story.id) == nil || canEditCard(story) else { return }
        let stored = taskBoard(for: story.projectId).story(id: story.id)
        upsertStory(story, defaultAssignee: defaultAssignee)
        guard let stored else { return }
        let removed = stored.linkedProjectIds.filter { !story.linkedProjectIds.contains($0) }
        let added = story.linkedProjectIds.filter { !stored.linkedProjectIds.contains($0) }
        if !removed.isEmpty {
            unlinkStory(story.id, in: story.projectId, from: removed)
        }
        if !added.isEmpty {
            await linkStory(story.id, in: story.projectId, to: added)
        }
    }

    /// Every task in a story across all the projects it is linked to.
    func tasks(inStory story: ProjectStory) -> [ProjectTask] {
        story.projectGroup.flatMap { taskBoard(for: $0).tasks(inStory: story.id) }
    }

    /// Deletes a story from every board it is linked to. Its tasks are kept and
    /// orphaned back to the board root rather than deleted — losing tracked
    /// work to a container delete would be surprising.
    func deleteStory(_ story: ProjectStory) {
        guard canEditCard(story) else { return }
        let stored = taskBoard(for: story.projectId).story(id: story.id) ?? story
        for projectId in stored.projectGroup {
            removeStoryCopy(story.id, from: projectId)
        }
    }

    /// Shares a story with more projects. Each newly linked board gets a copy
    /// of the story under the same id, so tasks there can join it.
    @discardableResult
    func linkStory(_ storyId: UUID, in projectId: UUID, to projectIds: [UUID]) async -> ProjectStory? {
        let known = Set(projects.map(\.id))
        for id in projectIds where known.contains(id) {
            await ensureTaskBoardLoaded(for: id)
        }
        guard var story = taskBoard(for: projectId).story(id: storyId) else { return nil }
        let group = story.projectGroup + projectIds.filter { known.contains($0) }
        var seen: Set<UUID> = []
        let deduped = group.filter { seen.insert($0).inserted }
        story.updatedAt = Date()
        writeStoryCopies(story, group: deduped)
        return taskBoard(for: projectId).story(id: storyId)
    }

    /// Stops sharing a story with the given projects. Their copies are removed
    /// and their tasks orphaned; the remaining copies keep the story.
    @discardableResult
    func unlinkStory(_ storyId: UUID, in projectId: UUID, from projectIds: [UUID]) -> ProjectStory? {
        guard var story = taskBoard(for: projectId).story(id: storyId) else { return nil }
        let removed = Set(projectIds)
        let remaining = story.projectGroup.filter { !removed.contains($0) }
        for id in story.projectGroup where removed.contains(id) {
            removeStoryCopy(storyId, from: id)
        }
        guard let anchor = remaining.first else { return nil }
        story.updatedAt = Date()
        writeStoryCopies(story, group: remaining)
        return taskBoard(for: anchor).story(id: storyId)
    }

    /// Writes the story onto its own board and onto every loaded board of a
    /// still-registered project in `group`. Unloaded boards are skipped rather
    /// than written, which would replace them with an empty board.
    private func writeStoryCopies(_ story: ProjectStory, group: [UUID]) {
        let known = Set(projects.map(\.id))
        let group = group.filter { $0 == story.projectId || (known.contains($0) && taskBoards[$0] != nil) }
        for target in group {
            updateBoard(target) { board in
                let existing = board.story(id: story.id)
                // Item types are per board, so a copy keeps its own type unless
                // the source's type also exists on this board.
                let typeId = target == story.projectId
                    ? story.typeId
                    : (board.itemType(id: story.typeId) != nil ? story.typeId : existing?.typeId)
                var copy = story.mirrored(into: target, group: group, typeId: typeId)
                if let existing { copy.createdAt = existing.createdAt }
                if let idx = board.stories.firstIndex(where: { $0.id == copy.id }) {
                    board.stories[idx] = copy
                } else {
                    board.stories.append(copy)
                }
            }
        }
    }

    private func removeStoryCopy(_ storyId: UUID, from projectId: UUID) {
        guard taskBoards[projectId]?.story(id: storyId) != nil else { return }
        updateBoard(projectId) { board in
            board.stories.removeAll { $0.id == storyId }
            for idx in board.tasks.indices where board.tasks[idx].storyId == storyId {
                board.tasks[idx].storyId = nil
            }
        }
    }
}
