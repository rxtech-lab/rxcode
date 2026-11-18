import Foundation
import os
import RxCodeCore

extension AppState {
    /// No agent is dispatched: this queries actual task/thread state at execution time.
    func makePetProgressReport(for task: ScheduledTask, now: Date = .now) async -> String {
        guard let projectID = task.projectId, let project = projects.first(where: { $0.id == projectID }) else {
            return "Scheduled progress check: the requested project no longer exists. No check or project action was performed."
        }
        await ensureTaskBoardLoaded(for: projectID)
        let board = taskBoard(for: projectID)
        let counts = Dictionary(grouping: board.tasks, by: \.status).map { status, tasks in
            "\(tasks.count) \(board.column(for: status).name)"
        }.sorted().joined(separator: ", ")
        let saved = await threadStoreReader.loadSummaries()
        var summaries = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, second in first.updatedAt > second.updatedAt ? first : second })
        for summary in allSessionSummaries { summaries[summary.id] = summary }
        let threads = summaries.values.filter { $0.projectId == projectID && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
        let running = threads.filter { sessionStates[resolveCurrentSessionId($0.id)]?.isStreaming == true }.count
        let latest = threads.prefix(3).map { summary in
            let state = sessionStates[resolveCurrentSessionId(summary.id)]
            let reported = state?.messages.last(where: { $0.role == .assistant })?.content
                ?? threadStore.fetchThreadSummary(sessionId: summary.id)?.summary
            let detail = reported.map { " Latest agent report (unverified): \(SpokenTextChunker.sanitizeForSpeech(String($0.prefix(250))))." } ?? ""
            return "\(summary.title): \(state?.isStreaming == true ? "agent running" : "no agent currently streaming").\(detail)"
        }.joined(separator: "; ")
        return """
        Progress observed in \(project.name) at \(now.formatted(date: .abbreviated, time: .shortened)): \
        \(board.tasks.count) board tasks\(counts.isEmpty ? "" : " (\(counts))"); \(running) agents streaming. \
        \(latest.isEmpty ? "No saved project threads were found." : "Recent threads: \(latest).") \
        These are observed board labels and agent activity, not proof of tests, merges or deployments. No project action was dispatched by this check.
        """
    }

    /// Reminders are saved notification text, never agent/project instructions to execute.
    func makePetScheduledReport(for task: ScheduledTask) async -> String {
        if task.resolvedPetScheduleKind == .reminder { return task.prompt }
        return await makePetProgressReport(for: task)
    }

    func executePetScheduledReport(_ task: ScheduledTask) async {
        defer { scheduledPetChecksInFlight.remove(task.id) }
        // Claim is made synchronously by runDueScheduledTasks, before this task can suspend.
        let claim = task.claimedAt
        let revision = task.updatedAt
        guard claim != nil, scheduledTasks.contains(where: { $0.id == task.id && $0.claimedAt == claim && $0.updatedAt == revision }) else { return }
        do {
            try await persistScheduledTasks()
            // Cancellation/editing while the claim was being saved must prevent execution.
            guard scheduledTasks.contains(where: { $0.id == task.id && $0.claimedAt == claim && $0.updatedAt == revision }) else { return }
            let report = await makePetScheduledReport(for: task)
            guard let current = scheduledTasks.firstIndex(where: { $0.id == task.id && $0.claimedAt == claim && $0.updatedAt == revision }) else { return }
            scheduledTasks[current].lastRunAt = .now
            scheduledTasks[current].pendingPetReport = report
            scheduledTasks[current].petReportDeliveredAt = nil
            scheduledTaskRuns.insert(ScheduledTaskRun(taskId: task.id, projectId: task.projectId,
                status: .succeeded, finishedAt: .now, summary: ScheduledTaskRun.makeSummary(report)), at: 0)
            try await persistScheduledTasks()
            try await persistence.saveScheduledTaskRuns(scheduledTaskRuns)
            deliverPendingPetReports()
        } catch {
            // Surface the failure before any suspension so observers of the failed run always
            // see the alert alongside it.
            (scheduledPetReportReceiver ?? .shared).alertErrorMessage = "Could not persist the scheduled check or report: \(error.localizedDescription)"
            logger.error("Could not persist scheduled pet check: \(error.localizedDescription)")
            if scheduledTasks.first(where: { $0.id == task.id })?.lastRunAt == nil {
                scheduledTaskRuns.insert(ScheduledTaskRun(taskId: task.id, projectId: task.projectId, status: .failed,
                    finishedAt: .now, errorMessage: "Could not save the scheduler claim. No reminder or progress check was executed."), at: 0)
                try? await persistence.saveScheduledTaskRuns(scheduledTaskRuns)
            }
        }
    }

    func deliverPendingPetReports(pet receiver: PetController? = nil) {
        let pet = receiver ?? scheduledPetReportReceiver ?? .shared
        for task in scheduledTasks where task.pendingPetReport != nil && task.petReportDeliveredAt == nil {
            guard let report = task.pendingPetReport else { continue }
            pet.deliverScheduledReport(id: task.id, title: task.name, text: report) { [weak self] in
                guard let self, let index = self.scheduledTasks.firstIndex(where: { $0.id == task.id }) else { return }
                self.scheduledTasks[index].petReportDeliveredAt = .now
                self.scheduledTasks[index].pendingPetReport = nil
                do { try await self.persistScheduledTasks() }
                catch { self.logger.error("Could not acknowledge scheduled pet report: \(error.localizedDescription)") }
            }
        }
    }
}
