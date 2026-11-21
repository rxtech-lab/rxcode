import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

// MARK: - Preview

#Preview("Projects Sidebar") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    let projectIDs = [UUID(), UUID(), UUID()]

    state.projects = [
        Project(
            id: projectIDs[0],
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        ),
        Project(
            id: projectIDs[1],
            name: "MyApp",
            path: "/Users/developer/Projects/MyApp"
        ),
        Project(
            id: projectIDs[2],
            name: "SwiftPackage",
            path: "/Users/developer/Code/SwiftPackage"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectIDs[0],
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "2",
            projectId: projectIDs[0],
            title: "Fix bug",
            updatedAt: Date().addingTimeInterval(-3600),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "3",
            projectId: projectIDs[1],
            title: "Review PR",
            updatedAt: Date().addingTimeInterval(-86400),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - Empty") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    state.projects = []

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - Selected") {
    @Previewable @State var showingBriefing = false
    @Previewable @State var selected: UUID? = nil

    let state = MobileAppState()
    let projectID = UUID()

    state.projects = [
        Project(
            id: projectID,
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectID,
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        ),
        SessionSummary(
            id: "2",
            projectId: projectID,
            title: "Another thread",
            updatedAt: Date().addingTimeInterval(-600),
            isPinned: false,
            isArchived: false,
            isStreaming: false,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: .constant(projectID),
            showingBriefing: $showingBriefing
        )
    }
    .environmentObject(state)
}

#Preview("Projects Sidebar - iPhone (Stack)") {
    @Previewable @State var selected: UUID? = nil
    @Previewable @State var showingBriefing = false

    let state = MobileAppState()
    let projectIDs = [UUID(), UUID()]

    state.projects = [
        Project(
            id: projectIDs[0],
            name: "RxCode",
            path: "/Users/developer/Desktop/rxlab/RxCode"
        ),
        Project(
            id: projectIDs[1],
            name: "MyApp",
            path: "/Users/developer/Projects/MyApp"
        )
    ]

    state.sessions = [
        SessionSummary(
            id: "1",
            projectId: projectIDs[0],
            title: "Building feature",
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            isStreaming: true,
            attention: nil,
            todos: nil,
            hasUncheckedCompletion: false
        )
    ]

    return NavigationStack {
        ProjectsSidebar(
            selected: $selected,
            showingBriefing: $showingBriefing,
            showsBriefingItem: false,
            onOpenProject: { selected = $0 }
        )
    }
    .environmentObject(state)
}
