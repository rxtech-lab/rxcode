import Foundation

extension TaskBoard {
    /// Eligible parent tasks, grouped in story order. Tasks whose story was
    /// removed join the ungrouped tasks at the end.
    ///
    /// `allTasks` is every task that links may cross, keyed by id, so a
    /// candidate on this board is rejected when a chain through other
    /// projects' boards would make a cycle. `nil` checks this board alone.
    public func parentTaskGroups(
        for taskID: UUID,
        matching search: String = "",
        linkingAcross allTasks: [UUID: ProjectTask]? = nil
    ) -> [ParentTaskGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup = allTasks ?? tasksByID
        let eligible = tasks.filter { Self.canLinkTask(taskID, to: $0.id, in: lookup) }
        let storyIDs = Set(stories.map(\.id))
        var groups = stories.compactMap { story -> ParentTaskGroup? in
            let matchesStory = story.title.localizedCaseInsensitiveContains(query)
            let matches = eligible.filter {
                $0.storyId == story.id && (query.isEmpty || matchesStory || $0.title.localizedCaseInsensitiveContains(query))
            }
            return matches.isEmpty ? nil : ParentTaskGroup(story: story, tasks: matches)
        }
        let ungrouped = eligible.filter {
            ($0.storyId.map { !storyIDs.contains($0) } ?? true)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
        if !ungrouped.isEmpty {
            groups.append(ParentTaskGroup(story: nil, tasks: ungrouped))
        }
        return groups
    }

    /// This board's tasks keyed by id.
    public var tasksByID: [UUID: ProjectTask] {
        Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A parent must be on this board and cannot make a dependency cycle.
    public func canLinkTask(_ taskID: UUID, to parentID: UUID) -> Bool {
        Self.canLinkTask(taskID, to: parentID, in: tasksByID)
    }

    /// A parent must be one of `tasks`, which may span several projects'
    /// boards, and cannot make a dependency cycle.
    public static func canLinkTask(_ taskID: UUID, to parentID: UUID, in tasks: [UUID: ProjectTask]) -> Bool {
        guard tasks[parentID] != nil, parentID != taskID else { return false }
        var visited: Set<UUID> = []
        var pending = [parentID]
        while let id = pending.popLast() {
            if id == taskID { return false }
            guard visited.insert(id).inserted else { continue }
            guard let parent = tasks[id] else { return false }
            pending.append(contentsOf: parent.parentTaskIds)
        }
        return true
    }

    /// A parent's work is ready for dependent tasks once it reaches Pending
    /// Review or a column that counts as done.
    public func isReadyParent(_ task: ProjectTask) -> Bool {
        let column = column(for: task.status)
        return column.id == .pendingReview || column.countsAsDone
    }

    /// This board's tasks that are ready for dependent work. Include parents
    /// already there so links added later and boards saved by older versions
    /// can catch up.
    public func readyParentIDs() -> Set<UUID> {
        Set(tasks.compactMap { isReadyParent($0) ? $0.id : nil })
    }

    /// Advance queued children whose parent is ready for dependent work. The
    /// parents may be on another project's board, so they are identified by
    /// id alone. Returns children moved into a chat column so the app can
    /// dispatch them.
    public mutating func advanceChildren(of readyParentIDs: Set<UUID>) -> [ProjectTask] {
        guard !readyParentIDs.isEmpty,
              let target = effectiveColumns.first(where: { $0.id == .inProgress }) ?? firstChatColumn
        else { return [] }
        var moved: [ProjectTask] = []
        for index in tasks.indices {
            let parents = tasks[index].parentTaskIds
            guard !parents.isEmpty,
                  parents.allSatisfy(readyParentIDs.contains),
                  tasks[index].attentionReason == nil,
                  !column(for: tasks[index].status).countsAsDone,
                  column(for: tasks[index].status).id != .pendingReview,
                  !column(for: tasks[index].status).triggersChat
            else { continue }
            tasks[index].status = target.id
            tasks[index].sortIndex = appendSortIndex(for: target.id)
            tasks[index].updatedAt = Date()
            moved.append(tasks[index])
        }
        return target.triggersChat ? moved : []
    }

}
