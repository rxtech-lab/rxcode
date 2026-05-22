import Foundation
import RxCodeCore
import RxCodeSync

/// Deterministic test data served by `MockRelayServer`.
///
/// Two projects, two threads each, one branch briefing per project, and a few
/// plain-text messages per thread — enough to drive the briefing and projects
/// navigation flows the UI tests exercise.
nonisolated struct MockFixtures: Sendable {

    let projects: [Project]
    let sessions: [SessionSummary]
    let branchBriefings: [MobileBranchBriefing]
    let threadSummaries: [MobileThreadSummary]
    /// Full message list keyed by session id.
    let messagesBySession: [String: [ChatMessage]]

    /// Builds a `snapshot` payload for whichever session the app is asking
    /// about. When `activeSessionID` has fixture messages they are embedded as
    /// the active page; otherwise the app just gets the project/thread lists.
    func snapshot(activeSessionID: String?) -> SnapshotPayload {
        let messages = activeSessionID.flatMap { messagesBySession[$0] }
        return SnapshotPayload(
            projects: projects,
            sessions: sessions,
            branchBriefings: branchBriefings,
            threadSummaries: threadSummaries,
            settings: nil,
            activeSessionID: activeSessionID,
            activeSessionMessages: messages,
            activeSessionHasMore: false,
            projectBranches: nil,
            usage: nil,
            hostMetrics: nil,
            runProfiles: nil,
            runTasks: nil,
            webProxy: nil
        )
    }

    /// The standard fixture set used by every UI test.
    static func standard() -> MockFixtures {
        let projectAlpha = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let projectBeta = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
        let branch = "main"
        // Fixed timestamp keeps every encoded payload byte-stable across runs.
        let now = Date(timeIntervalSince1970: 1_716_000_000)

        let projects = [
            Project(id: projectAlpha, name: "Project Alpha", path: "/tmp/project-alpha"),
            Project(id: projectBeta, name: "Project Beta", path: "/tmp/project-beta"),
        ]

        struct ThreadSpec {
            let sessionId: String
            let projectId: UUID
            let title: String
        }
        let specs = [
            ThreadSpec(sessionId: "sess-alpha-1", projectId: projectAlpha, title: "Alpha Thread One"),
            ThreadSpec(sessionId: "sess-alpha-2", projectId: projectAlpha, title: "Alpha Thread Two"),
            ThreadSpec(sessionId: "sess-beta-1", projectId: projectBeta, title: "Beta Thread One"),
            ThreadSpec(sessionId: "sess-beta-2", projectId: projectBeta, title: "Beta Thread Two"),
        ]

        let sessions = specs.map { spec in
            SessionSummary(
                id: spec.sessionId,
                projectId: spec.projectId,
                title: spec.title,
                updatedAt: now,
                isPinned: false,
                isArchived: false
            )
        }

        let threadSummaries = specs.map { spec in
            MobileThreadSummary(
                sessionId: spec.sessionId,
                projectId: spec.projectId,
                branch: branch,
                title: spec.title,
                summary: "Summary of \(spec.title).",
                updatedAt: now
            )
        }

        let branchBriefings = [
            MobileBranchBriefing(
                projectId: projectAlpha,
                branch: branch,
                briefing: "Briefing for Project Alpha on main.",
                updatedAt: now
            ),
            MobileBranchBriefing(
                projectId: projectBeta,
                branch: branch,
                briefing: "Briefing for Project Beta on main.",
                updatedAt: now
            ),
        ]

        var messagesBySession: [String: [ChatMessage]] = [:]
        for spec in specs {
            messagesBySession[spec.sessionId] = [
                ChatMessage(
                    role: .user,
                    content: "Hello from \(spec.title).",
                    timestamp: now
                ),
                ChatMessage(
                    role: .assistant,
                    content: "Assistant reply inside \(spec.title).",
                    isResponseComplete: true,
                    timestamp: now
                ),
                ChatMessage(
                    role: .user,
                    content: "Follow-up question in \(spec.title).",
                    timestamp: now
                ),
            ]
        }

        return MockFixtures(
            projects: projects,
            sessions: sessions,
            branchBriefings: branchBriefings,
            threadSummaries: threadSummaries,
            messagesBySession: messagesBySession
        )
    }
}
