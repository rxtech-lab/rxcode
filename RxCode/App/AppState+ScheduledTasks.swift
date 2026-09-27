import Foundation
import RxCodeCore
import os

extension AppState {

    // MARK: - Scheduled Tasks

    func loadScheduledTasksFromDisk() async {
        scheduledTasks = await persistence.loadScheduledTasks()
    }

    /// Inserts `task`, or replaces the stored task with the same id, and
    /// persists the list.
    func upsertScheduledTask(_ task: ScheduledTask) {
        var task = task
        task.updatedAt = .now
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx] = task
        } else {
            scheduledTasks.append(task)
            AnalyticsService.shared.log(.scheduledTaskCreated)
        }
        saveScheduledTasks()
    }

    func setScheduledTaskEnabled(id: UUID, _ enabled: Bool) {
        guard let idx = scheduledTasks.firstIndex(where: { $0.id == id }),
              scheduledTasks[idx].isEnabled != enabled
        else { return }
        scheduledTasks[idx].isEnabled = enabled
        scheduledTasks[idx].updatedAt = .now
        saveScheduledTasks()
    }

    func deleteScheduledTask(id: UUID) {
        scheduledTasks.removeAll { $0.id == id }
        saveScheduledTasks()
    }

    /// Drops every scheduled task of a project being removed.
    func deleteScheduledTasks(projectId: UUID) {
        guard scheduledTasks.contains(where: { $0.projectId == projectId }) else { return }
        scheduledTasks.removeAll { $0.projectId == projectId }
        saveScheduledTasks()
    }

    /// The agent a run of `task` uses: its own model, else the default task
    /// agent resolved at run time.
    func resolvedAgent(for task: ScheduledTask) -> TaskAgentConfig {
        task.agent.isAssigned ? task.agent : defaultTaskAgent()
    }

    // MARK: - Agent Proposals

    /// Queues `proposal` for the user to confirm and waits for their decision.
    /// Returns the task as added (possibly edited by the user), or `nil` when
    /// they cancel or the waiting call is cancelled.
    func confirmScheduledTaskProposal(_ proposal: ScheduledTask) async -> ScheduledTask? {
        let id = proposal.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                scheduledTaskProposalContinuations[id] = continuation
                scheduledTaskProposals.append(proposal)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveScheduledTaskProposal(id: id, with: nil)
            }
        }
    }

    /// Settles the proposal `id`: adds `task` when non-nil and resumes the
    /// waiting tool call. A no-op for proposals already settled, so the sheet
    /// can resolve on both its buttons and its disappearance.
    func resolveScheduledTaskProposal(id: UUID, with task: ScheduledTask?) {
        guard let continuation = scheduledTaskProposalContinuations.removeValue(forKey: id) else { return }
        scheduledTaskProposals.removeAll { $0.id == id }
        if let task {
            upsertScheduledTask(task)
        }
        continuation.resume(returning: task)
    }

    private func saveScheduledTasks() {
        let tasks = scheduledTasks
        Task { [persistence, logger] in
            do {
                try await persistence.saveScheduledTasks(tasks)
            } catch {
                logger.error("Failed to save scheduled tasks: \(error.localizedDescription)")
            }
        }
    }
}
