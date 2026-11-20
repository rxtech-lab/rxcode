import RxCodeCore
import RxCodeSync
import SwiftUI
import os

// MARK: - Previews

#if DEBUG
extension MobileAppState {
    /// A preview-ready MobileAppState with sample projects and sessions.
    static var preview: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()

        state.projects = [
            Project(id: projectID, name: "RxCode", path: "/Users/dev/RxCode")
        ]

        state.sessions = [
            SessionSummary(
                id: "session-1",
                projectId: projectID,
                title: "Building new feature module",
                updatedAt: Date(),
                isPinned: false,
                isArchived: false,
                isStreaming: true,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Create models", activeForm: "Creating models", status: .completed),
                    TodoItem(id: 2, content: "Add views", activeForm: "Adding views", status: .inProgress),
                    TodoItem(id: 3, content: "Write tests", activeForm: "Writing tests", status: .pending)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-2",
                projectId: projectID,
                title: "Implement Liquid Glass UI",
                updatedAt: Date().addingTimeInterval(-300),
                isPinned: true,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: [
                    TodoItem(id: 1, content: "Task 1", activeForm: "Doing task 1", status: .completed),
                    TodoItem(id: 2, content: "Task 2", activeForm: "Doing task 2", status: .completed),
                    TodoItem(id: 3, content: "Task 3", activeForm: "Doing task 3", status: .completed)
                ],
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-3",
                projectId: projectID,
                title: "Deploy to production",
                updatedAt: Date().addingTimeInterval(-120),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .permission,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-4",
                projectId: projectID,
                title: "Code review assistance",
                updatedAt: Date().addingTimeInterval(-600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: .question,
                todos: nil,
                hasUncheckedCompletion: false
            ),
            SessionSummary(
                id: "session-5",
                projectId: projectID,
                title: "Fix scrolling performance",
                updatedAt: Date().addingTimeInterval(-3600),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: true
            ),
            SessionSummary(
                id: "session-6",
                projectId: projectID,
                title: "Review pull request",
                updatedAt: Date().addingTimeInterval(-86400),
                isPinned: false,
                isArchived: false,
                isStreaming: false,
                attention: nil,
                todos: nil,
                hasUncheckedCompletion: false
            )
        ]

        return state
    }

    /// A preview-ready MobileAppState with no sessions (empty state).
    static var previewEmpty: MobileAppState {
        let state = MobileAppState()
        let projectID = UUID()

        state.projects = [
            Project(id: projectID, name: "New Project", path: "/Users/dev/NewProject")
        ]
        state.sessions = []

        return state
    }
}

#Preview("Sessions List") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - With Selection") {
    let state = MobileAppState.preview
    let projectID = state.projects.first!.id
    let selectedID = state.sessions.first?.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(selectedID),
            usesSelection: true
        )
    }
    .environmentObject(state)
}

#Preview("Sessions List - Empty") {
    let state = MobileAppState.previewEmpty
    let projectID = state.projects.first!.id

    NavigationStack {
        SessionsList(
            projectID: projectID,
            selected: .constant(nil)
        )
    }
    .environmentObject(state)
}
#endif
