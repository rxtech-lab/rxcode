import Foundation
import RxCodeCore

// MARK: - Daily Report Model & Generator

nonisolated struct PetDailyReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let generatedAt: Date
    let workspaceName: String
    let spokenSummary: String
    let markdownBody: String
    let completedTasksCount: Int
    let inProgressTasksCount: Int
    let pendingReviewTasksCount: Int
    let activeThreadsCount: Int
    let briefingsCount: Int
    let scheduledRunsCount: Int
    let ciFailing: Bool
}

@MainActor
enum PetDailyReportService {
    struct Snapshot: Sendable {
        var workspaceName: String
        var completedTasks: [(project: String, title: String)]
        var inProgressTasks: [(project: String, title: String)]
        var reviewTasks: [(project: String, title: String)]
        var attentionTasks: [(project: String, title: String, reason: String)]
        var recentThreads: [(project: String, title: String, provider: String)]
        var recentBriefings: [String]
        var scheduledSucceeded: Int
        var scheduledFailed: Int
        var activeJobsCount: Int
        var ciFailing: Bool
        var plans: [CodingPlanActivity] = []
        var planProjectNames: [UUID: String] = [:]
        var planHistoryUnavailable = false
    }

    static func captureSnapshot(from appState: AppState, now: Date = Date()) async -> Snapshot {
        let cutoff = now.addingTimeInterval(-86_400)
        let projectNames = Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0.name) })

        var completed: [(String, String)] = []
        var inProgress: [(String, String)] = []
        var review: [(String, String)] = []
        var attention: [(String, String, String)] = []

        for project in appState.projects {
            let board = appState.taskBoard(for: project.id)
            let pName = project.name
            for task in board.tasks {
                switch task.status {
                case .done:
                    if task.updatedAt >= cutoff {
                        completed.append((pName, task.title))
                    }
                case .inProgress:
                    inProgress.append((pName, task.title))
                case .pendingReview:
                    review.append((pName, task.title))
                default:
                    break
                }
                if let reason = task.attentionReason, !reason.isEmpty, task.status != .done {
                    attention.append((pName, task.title, reason))
                }
            }
        }

        let recentThreads: [(String, String, String)] = appState.allSessionSummaries
            .filter { !$0.isArchived && $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(10)
            .map { summary in
                let pName = projectNames[summary.projectId] ?? "General"
                let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return (pName, title.isEmpty ? "Untitled Thread" : title, summary.agentProvider.displayNameText)
            }

        let recentBriefings = appState.briefingDocuments
            .filter { $0.isPublished && ($0.publishedAt ?? $0.updatedAt) >= cutoff }
            .sorted { ($0.publishedAt ?? $0.updatedAt) > ($1.publishedAt ?? $1.updatedAt) }
            .prefix(6)
            .map(\.title)

        let recentScheduled = appState.scheduledTaskRuns.filter { $0.startedAt >= cutoff }
        let schedSucceeded = recentScheduled.filter { $0.status == .succeeded }.count
        let schedFailed = recentScheduled.filter { $0.status == .failed }.count

        var snapshot = Snapshot(
            workspaceName: appState.activeWorkspace.name,
            completedTasks: completed,
            inProgressTasks: inProgress,
            reviewTasks: review,
            attentionTasks: attention,
            recentThreads: recentThreads,
            recentBriefings: Array(recentBriefings),
            scheduledSucceeded: schedSucceeded,
            scheduledFailed: schedFailed,
            activeJobsCount: appState.inProgressSessionCount,
            ciFailing: appState.anyCIFailing
        )
        snapshot.planProjectNames = projectNames
        do {
            snapshot.plans = try await appState.codingPlanActivities().filter {
                $0.updatedAt >= cutoff || $0.implementationStatus != "implemented"
            }
        } catch {
            snapshot.planHistoryUnavailable = true
        }
        return snapshot
    }

    nonisolated static func formatDeterministicReport(from snapshot: Snapshot, generatedAt: Date = Date()) -> PetDailyReport {
        var spokenParts: [String] = []
        if snapshot.completedTasks.isEmpty && snapshot.recentThreads.isEmpty && snapshot.inProgressTasks.isEmpty
            && snapshot.plans.isEmpty && !snapshot.planHistoryUnavailable {
            spokenParts.append("Here is your daily report for \(snapshot.workspaceName). Everything is quiet so far today, with no active tasks or recent threads in the last twenty-four hours.")
        } else {
            spokenParts.append("Here is your daily report for \(snapshot.workspaceName).")
            if !snapshot.completedTasks.isEmpty {
                let count = snapshot.completedTasks.count
                spokenParts.append("You completed \(count) \(count == 1 ? "task" : "tasks") in the last twenty-four hours.")
            }
            if !snapshot.inProgressTasks.isEmpty || !snapshot.reviewTasks.isEmpty {
                spokenParts.append("There \(snapshot.inProgressTasks.count == 1 ? "is" : "are") \(snapshot.inProgressTasks.count) in progress and \(snapshot.reviewTasks.count) waiting for review.")
            }
            if !snapshot.recentThreads.isEmpty {
                spokenParts.append("\(snapshot.recentThreads.count) chat \(snapshot.recentThreads.count == 1 ? "thread was" : "threads were") active recently.")
            }
        }
        if let latest = snapshot.plans.first {
            let title = SpokenTextChunker.sanitizeForSpeech(String(latest.title.prefix(120)))
            spokenParts.append("The latest coding plan is \(title). Its plan status is \(latest.planningStatusLabel.lowercased()) and its implementation status is \(latest.implementationStatusLabel.lowercased()).")
        }
        if snapshot.ciFailing {
            spokenParts.append("Heads up: at least one CI workflow is currently failing.")
        } else if !snapshot.attentionTasks.isEmpty {
            spokenParts.append("\(snapshot.attentionTasks.count) \(snapshot.attentionTasks.count == 1 ? "task needs" : "tasks need") your attention.")
        }

        let spoken = spokenParts.joined(separator: " ")

        var md: [String] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        md.append("# Daily Workspace Report — \(snapshot.workspaceName)")
        md.append("_Generated \(formatter.string(from: generatedAt)) · Last 24 hours_")
        md.append("")
        md.append("## Highlights")
        md.append("- **Completed tasks:** \(snapshot.completedTasks.count)")
        md.append("- **In progress:** \(snapshot.inProgressTasks.count) (\(snapshot.activeJobsCount) live \(snapshot.activeJobsCount == 1 ? "stream" : "streams"))")
        md.append("- **Pending review:** \(snapshot.reviewTasks.count)")
        md.append("- **Active threads (24h):** \(snapshot.recentThreads.count)")
        if snapshot.scheduledSucceeded > 0 || snapshot.scheduledFailed > 0 {
            md.append("- **Scheduled runs (24h):** \(snapshot.scheduledSucceeded) succeeded, \(snapshot.scheduledFailed) failed")
        }
        if snapshot.ciFailing {
            md.append("- **CI Status:** Failing checks detected")
        }

        if !snapshot.completedTasks.isEmpty {
            md.append("")
            md.append("## Completed Tasks")
            for item in snapshot.completedTasks.prefix(12) {
                md.append("- **[\(item.project)]** \(item.title)")
            }
        }

        if !snapshot.reviewTasks.isEmpty || !snapshot.inProgressTasks.isEmpty {
            md.append("")
            md.append("## Active & Pending Review")
            for item in snapshot.reviewTasks.prefix(10) {
                md.append("- **[\(item.project)]** \(item.title) _(Pending Review)_")
            }
            for item in snapshot.inProgressTasks.prefix(10) {
                md.append("- **[\(item.project)]** \(item.title) _(In Progress)_")
            }
        }

        if !snapshot.plans.isEmpty || snapshot.planHistoryUnavailable {
            md.append("")
            md.append("## Coding Plans")
            if snapshot.planHistoryUnavailable {
                md.append("Coding plan history could not be loaded.")
            }
            let groups = Dictionary(grouping: snapshot.plans, by: \.implementationStatusLabel)
            for status in groups.keys.sorted() {
                guard let plans = groups[status] else { continue }
                md.append("")
                md.append("### \(status) (\(plans.count))")
                for plan in plans.prefix(6) {
                    let project = snapshot.planProjectNames[plan.projectID] ?? "General"
                    md.append("- **[\(project)] \(plan.title)** — \(plan.planningStatusLabel). \(plan.implementationEvidence)")
                    if !plan.featureExcerpt.isEmpty {
                        md.append("  \(plan.featureExcerpt.replacingOccurrences(of: "\n", with: "\n  "))")
                    }
                    md.append("  \(plan.versionLabel) · Plan ID: `\(plan.id.uuidString)`")
                }
                if plans.count > 6 { md.append("- \(plans.count - 6) more in this group.") }
            }
        }

        if !snapshot.attentionTasks.isEmpty {
            md.append("")
            md.append("## Needs Attention")
            for item in snapshot.attentionTasks.prefix(8) {
                md.append("- **[\(item.project)]** \(item.title) — \(item.reason)")
            }
        }

        if !snapshot.recentThreads.isEmpty {
            md.append("")
            md.append("## Recent Threads")
            for thread in snapshot.recentThreads.prefix(8) {
                md.append("- **[\(thread.project)]** \(thread.title) _(\(thread.provider))_")
            }
        }

        if !snapshot.recentBriefings.isEmpty {
            md.append("")
            md.append("## Published Briefings")
            for title in snapshot.recentBriefings {
                md.append("- \(title)")
            }
        }

        return PetDailyReport(
            id: UUID(),
            generatedAt: generatedAt,
            workspaceName: snapshot.workspaceName,
            spokenSummary: spoken,
            markdownBody: md.joined(separator: "\n"),
            completedTasksCount: snapshot.completedTasks.count,
            inProgressTasksCount: snapshot.inProgressTasks.count,
            pendingReviewTasksCount: snapshot.reviewTasks.count,
            activeThreadsCount: snapshot.recentThreads.count,
            briefingsCount: snapshot.recentBriefings.count,
            scheduledRunsCount: snapshot.scheduledSucceeded + snapshot.scheduledFailed,
            ciFailing: snapshot.ciFailing
        )
    }

    static func generate(for appState: AppState, companion: PetController) async -> PetDailyReport {
        let snapshot = await captureSnapshot(from: appState)
        let base = formatDeterministicReport(from: snapshot)

        // The current voice assistant summarizes the report itself during a conversation.
        guard !companion.isVoiceActive else { return base }

        // Ask the configured general AI model for a concise, natural spoken summary if available.
        let aiPrompt = """
        Write a friendly, concise 2-to-3 sentence spoken daily standup summary for the developer based on this workspace report.
        Rules:
        - Plain spoken text only: no markdown, no bullet points, no backticks, no symbols.
        \(companion.configuration.conversationLanguageInstruction)
        - Highlight completed work, items waiting for review, and anything needing attention.
        - When coding plans are present, mention a relevant planned feature and its recorded implementation status. A ready or approved plan alone does not establish implementation.
        - Keep it under 65 words.

        Report data:
        \(base.markdownBody)
        """

        if let polishedSpoken = await appState.runTaskAgentCompletion(
            prompt: aiPrompt,
            projectId: companion.configuration.pinnedProjectId ?? appState.projects.first?.id,
            model: companion.configuration.customAgent.map { .agent($0) } ?? .taskAgent
        ) {
            let cleaned = SpokenTextChunker.sanitizeForSpeech(polishedSpoken)
            if !cleaned.isEmpty {
                return PetDailyReport(
                    id: base.id,
                    generatedAt: base.generatedAt,
                    workspaceName: base.workspaceName,
                    spokenSummary: cleaned,
                    markdownBody: base.markdownBody,
                    completedTasksCount: base.completedTasksCount,
                    inProgressTasksCount: base.inProgressTasksCount,
                    pendingReviewTasksCount: base.pendingReviewTasksCount,
                    activeThreadsCount: base.activeThreadsCount,
                    briefingsCount: base.briefingsCount,
                    scheduledRunsCount: base.scheduledRunsCount,
                    ciFailing: base.ciFailing
                )
            }
        }

        return base
    }
}
