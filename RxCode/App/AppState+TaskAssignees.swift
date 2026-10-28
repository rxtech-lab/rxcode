import Foundation
import RxAuthSwift
import RxCodeCore

/// Project-member choices and card edit permissions shared by task and story views.
extension AppState {
    func cardAssigneeMembers(projectID: UUID) -> [CardAssignee] {
        var members = taskBoard(for: projectID).cloudSync?.members ?? []
        if let user = rxAuth.user, !members.contains(where: { $0.id == user.id }) {
            members.append(CardAssignee(userId: user.id, name: user.name, email: user.email, image: user.image))
        }
        return members.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The person acting on this Mac: the signed-in account, or the macOS
    /// user when signed out. Recorded as a delay's author and a task's reviewer.
    var cardActor: CardAssignee {
        if let user = rxAuth.user {
            return CardAssignee(userId: user.id, name: user.name, email: user.email, image: user.image)
        }
        let fullName = NSFullUserName()
        return CardAssignee(userId: "local:\(NSUserName())", name: fullName.isEmpty ? NSUserName() : fullName)
    }

    func canEditCard(_ task: ProjectTask) -> Bool {
        let board = taskBoard(for: task.projectId)
        let stored = board.tasks.first { $0.id == task.id } ?? task
        return board.canEditCard(assigneeIds: stored.assigneeIds, userID: rxAuth.user?.id)
    }

    func canEditCard(_ story: ProjectStory) -> Bool {
        let board = taskBoard(for: story.projectId)
        let stored = board.story(id: story.id) ?? story
        return board.canEditCard(assigneeIds: stored.assigneeIds, userID: rxAuth.user?.id)
    }
}
