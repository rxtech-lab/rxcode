import RxCodeCore
import SwiftUI

/// Converts a reviewed AI suggestion into an unsaved task or story for the creation form.
struct MobileBoardAICreationSheet: View {
    let board: TaskBoard
    let task: ProjectTask
    let isStory: Bool
    let onTask: (ProjectTask) -> Void
    let onStory: (ProjectStory) -> Void

    var body: some View {
        MobileAIDraftSheet(
            board: board,
            kind: isStory ? .story : .task,
            storyTitle: isStory ? nil : board.story(id: task.storyId)?.title,
            candidates: isStory ? [] : TaskClassification.startsAfterCandidates(for: task, board: board).map(\.title)
        ) { draft in
            if isStory {
                var result = ProjectStory(projectId: task.projectId, title: draft.title)
                result.details = draft.details
                draft.classification.apply(to: &result, board: board)
                onStory(result)
            } else {
                var result = task
                result.title = draft.title
                result.details = draft.details
                draft.classification.apply(to: &result, board: board)
                onTask(result)
            }
        }
    }
}
