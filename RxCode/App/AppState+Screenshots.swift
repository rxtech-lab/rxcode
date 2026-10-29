#if DEBUG
import Foundation
import RxCodeCore

extension AppState {
    /// Fictional data only. This path bypasses service startup and normal workspace loading.
    func initializeScreenshotWorkspace() async {
        selectedTheme = .rxcode
        ThemeStore.shared.current = selectedTheme
        let root = AppSupport.bundleScopedURL.appendingPathComponent("Demo Projects")
        projects = ["Orbit Studio", "Atlas Notes", "Beacon API"].map {
            Project(name: $0, path: root.appendingPathComponent($0).path)
        }
        let titles = [
            ["Design the command palette", "Add keyboard shortcuts", "Polish the onboarding flow"],
            ["Build the activity timeline", "Add saved workspace views", "Improve search ranking"],
            ["Review accessibility labels", "Verify the offline cache", "Test workspace restore"],
            ["Ship the new navigation", "Add dark mode tokens", "Document the component library"],
        ]
        let statuses: [TaskStatus] = [.pending, .inProgress, .pendingReview, .done]
        let agents: [TaskAgentConfig] = [
            .init(provider: .claudeCode, model: "claude-sonnet-4-5"),
            .init(provider: .codex, model: "gpt-5-codex"),
            .init(provider: .acp, model: "gemini-2.5-pro"),
        ]
        for project in projects {
            try? FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
            var tasks: [ProjectTask] = []
            for (column, names) in titles.enumerated() {
                for (index, title) in names.enumerated() {
                    tasks.append(ProjectTask(
                        projectId: project.id, title: title,
                        details: "Build a thoughtful, accessible experience for the Orbit demo workspace.",
                        status: statuses[column], version: "v1.2", tags: [index == 1 ? "experience" : "design"],
                        priority: index == 0 ? .high : .medium, agent: agents[index], sortIndex: Double(index)
                    ))
                }
            }
            taskBoards[project.id] = TaskBoard(tasks: tasks)
            threadStore.upsertBranchBriefing(projectId: project.id, branch: "main", briefing: """
            ## A clearer workspace, ready for review

            The Orbit team completed the navigation refresh and brought the component library together.

            ### Shipped
            - **New navigation:** dedicated spaces for projects, chats, and schedules.
            - **Dark mode:** consistent colors and readable contrast across every panel.
            - **Component library:** shared buttons, cards, and empty states.

            ### Next up
            Review keyboard navigation, verify offline behavior, and finish the activity timeline.
            """)
            for (index, title) in ["Build the activity timeline", "Review the navigation refresh", "Plan the next release"].enumerated() {
                let session = ChatSession(
                    id: "demo-\(project.id)-\(index)", projectId: project.id, title: title,
                    messages: [
                        ChatMessage(role: .user, content: "Add an activity timeline to Orbit. Keep the layout calm, make every event easy to scan, and support keyboard navigation."),
                        ChatMessage(role: .assistant, content: """
                        ## The activity timeline is ready

                        I added a dedicated timeline with clear date groups and lightweight event cards.

                        - **Quick scanning** — updates are grouped by day with a concise summary.
                        - **Keyboard support** — move between events and open details without a mouse.
                        - **Focused details** — each event opens in its own sheet.

                        ### Validation
                        The timeline handles empty days, long titles, and offline updates. All 18 component checks passed.

                        Ready for your review in **Activity → Timeline**.
                        """, isResponseComplete: true),
                    ], agentProvider: agents[index].provider ?? .claudeCode,
                    model: agents[index].model, origin: .legacyRxCode
                )
                try? await persistence.saveSession(session, persistTitle: true)
                threadStore.upsert(session.summary)
            }
        }
        allSessionSummaries = threadStore.loadAllSummaries()
        scheduledTasks = [
            ("Morning project digest", "0 9 * * 1-5"),
            ("Weekly accessibility review", "0 10 * * 1"),
            ("Dependency health check", "0 14 * * 5"),
        ].enumerated().map { index, item in
            ScheduledTask(projectId: projects[index].id, name: item.0,
                          prompt: "Review the demo workspace and prepare a concise Markdown briefing.",
                          cronExpression: item.1, isEnabled: false, agent: agents[index])
        }
        branchBriefingRevision &+= 1
        isInitialized = true
    }
}
#endif
