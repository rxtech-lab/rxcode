import Foundation
import os
import RxCodeCore

/// Which device runs a cloud task.
///
/// A cloud board is shared by every Mac signed in to the account, and by
/// teammates' Macs. Each of them sees the same card enter a chat column, so
/// without coordination every one would start its own agent run. A task's
/// `assignedDeviceId` is the run lock:
///
/// - A move made on this Mac (drag, menu, form, or a phone that picked this
///   Mac) claims the task for this Mac right away.
/// - A run nobody picked a device for — a card moved in from another device
///   or the web, or a dependent task released by its parent — is claimed
///   first come, first served: the first Mac to write its ID to an unclaimed
///   task on Autopilot runs it, and every other Mac leaves it alone.
/// - A card claimed by another device shows where it is running and can't be
///   moved out of its chat column here until that run releases it.
///
/// Local-only projects have a single device, so none of this applies to them.
extension AppState {

    /// How long a claim on an older Autopilot waits before reading it back.
    /// Two Macs that claim the same task at once both see whichever write
    /// Autopilot kept last.
    static var taskClaimSettleDelay: Duration = .seconds(2)

    // MARK: - Reads

    /// Whether `task`'s board syncs through Autopilot, so other devices can
    /// run it too.
    func isCloudTask(_ task: ProjectTask) -> Bool {
        projects.first(where: { $0.id == task.projectId })?.isCloud == true
    }

    /// The device that owns `task`'s run when it isn't this Mac: the task sits
    /// in a chat column, claimed by another device, with no run here.
    func otherRunDeviceId(for task: ProjectTask) -> String? {
        guard isCloudTask(task),
              let owner = task.assignedDeviceId,
              owner != cloudDeviceID,
              task.sessionKey == nil,
              !task.isQueued,
              taskBoard(for: task.projectId).column(for: task.status).triggersChat
        else { return nil }
        return owner
    }

    /// Whether another device is running `task`. Its card shows that device
    /// and stays in its column here.
    func isRunningOnOtherDevice(_ task: ProjectTask) -> Bool {
        otherRunDeviceId(for: task) != nil
    }

    /// The name shown on a card running on another device. A teammate's Mac
    /// isn't registered on this account, so it has no name here.
    func otherRunDeviceName(for task: ProjectTask) -> String? {
        guard let owner = otherRunDeviceId(for: task) else { return nil }
        return cloudDevices.first(where: { $0.id == owner })?.name
            ?? String(localized: "another device")
    }

    // MARK: - Claiming

    /// Locks a run the user started on this Mac to this Mac. Other devices see
    /// the claim on their next sync and leave the task alone.
    func claimedForThisDevice(_ task: ProjectTask) -> ProjectTask {
        guard isCloudTask(task), !cloudDeviceID.isEmpty else { return task }
        var claimed = task
        claimed.assignedDeviceId = cloudDeviceID
        return claimed
    }

    /// Claims an unassigned cloud task for this Mac, first come, first served.
    /// Returns `true` when this Mac may run it.
    ///
    /// Autopilot takes the claim in one conditional update, so of two Macs
    /// racing for the same task exactly one wins. When Autopilot can't be
    /// reached the run goes ahead here; the claim is pushed with the next
    /// sync.
    func claimCloudTaskRun(_ task: ProjectTask) async -> Bool {
        guard isCloudTask(task) else { return true }
        let me = cloudDeviceID
        if let owner = task.assignedDeviceId { return owner == me }
        guard isSignedIn,
              let cloudId = projects.first(where: { $0.id == task.projectId })?.cloudId,
              let remoteId = taskBoard(for: task.projectId).cloudSync?.taskRemoteId(task.id)
        else {
            // Not uploaded yet, so no other device can have seen it.
            recordClaim(me, for: task, base: nil)
            return true
        }
        guard claimingTaskIds.insert(task.id).inserted else { return false }
        defer { claimingTaskIds.remove(task.id) }

        do {
            let claim = try await projectCloud.claimTask(projectId: cloudId, taskId: remoteId, deviceId: me)
            let owner = claim.task.fields.assignedDeviceId ?? me
            if !claim.claimed {
                logger.info("[Tasks] task \(task.id.uuidString, privacy: .public) was claimed by another device first")
            }
            recordClaim(owner, for: task, base: claim.task.fields)
            return claim.claimed
        } catch is CancellationError {
            return false
        } catch where ProjectCloudService.isNotFound(error) || ProjectCloudService.isMethodNotAllowed(error) {
            // An Autopilot without the claim endpoint; a deleted task is
            // caught again below.
            return await claimCloudTaskRunByReadBack(task, remoteId: remoteId, cloudId: cloudId)
        } catch {
            logger.warning("[Tasks] could not claim task \(task.id.uuidString, privacy: .public) on Autopilot: \(error.localizedDescription, privacy: .public)")
            recordClaim(me, for: task, base: nil)
            return true
        }
    }

    /// The claim for an Autopilot that predates `claimTask`: write the claim
    /// while the task is still unclaimed, then read it back after
    /// `taskClaimSettleDelay`, so racing Macs agree on whichever write
    /// Autopilot kept last.
    private func claimCloudTaskRunByReadBack(_ task: ProjectTask, remoteId: String, cloudId: String) async -> Bool {
        let me = cloudDeviceID
        do {
            guard let remote = try await remoteTask(remoteId, cloudId: cloudId) else { return false }
            if let owner = remote.fields.assignedDeviceId {
                recordClaim(owner, for: task, base: remote.fields)
                return owner == me
            }
            var fields = remote.fields
            fields.assignedDeviceId = me
            if let local = self.task(id: task.id) {
                fields.status = taskBoard(for: task.projectId).cloudStatus(for: local.status)
            }
            let written = try await projectCloud.updateTask(projectId: cloudId, taskId: remoteId, fields: fields)
            recordClaim(me, for: task, base: written.fields)

            try await Task.sleep(for: Self.taskClaimSettleDelay)
            guard let settled = try await remoteTask(remoteId, cloudId: cloudId) else { return false }
            let owner = settled.fields.assignedDeviceId ?? me
            if owner != me {
                logger.info("[Tasks] task \(task.id.uuidString, privacy: .public) was claimed by another device first")
                recordClaim(owner, for: task, base: settled.fields)
            }
            return owner == me
        } catch is CancellationError {
            return false
        } catch {
            logger.warning("[Tasks] could not claim task \(task.id.uuidString, privacy: .public) on Autopilot: \(error.localizedDescription, privacy: .public)")
            recordClaim(me, for: task, base: nil)
            return true
        }
    }

    /// The task `remoteId` as Autopilot has it now; `nil` once it's deleted.
    private func remoteTask(_ remoteId: String, cloudId: String) async throws -> CloudRemoteTask? {
        try await projectCloud.board(projectId: cloudId).tasks.first { $0.id == remoteId }
    }

    /// Writes `owner` onto the local task. With `base`, the value is what
    /// Autopilot stores, so it becomes the sync base and isn't sent back;
    /// without it the claim is pushed by the next sync.
    private func recordClaim(_ owner: String, for task: ProjectTask, base: CloudTaskFields?) {
        guard var board = taskBoards[task.projectId],
              let index = board.tasks.firstIndex(where: { $0.id == task.id })
        else { return }
        board.tasks[index].assignedDeviceId = owner
        guard let base, var sync = board.cloudSync, sync.tasks[task.id] != nil else {
            setTaskBoard(board, for: task.projectId)
            return
        }
        // Only the fields the claim wrote become the base, so another
        // device's unpulled edits still merge in on the next sync.
        var merged = sync.tasks[task.id]?.base ?? base
        merged.assignedDeviceId = base.assignedDeviceId
        if base.status == board.cloudStatus(for: board.tasks[index].status) {
            merged.status = base.status
        }
        sync.tasks[task.id]?.base = merged
        board.cloudSync = sync
        setTaskBoard(board, for: task.projectId, fromCloud: true)
    }

    // MARK: - Runs started elsewhere

    /// Whether a cloud pull that moved `before` to `after` starts a run here:
    /// the card entered a chat column from another device, unclaimed or
    /// claimed for this Mac, and isn't already running here.
    func remoteMoveStartsRun(from before: ProjectTask?, to after: ProjectTask, board: TaskBoard) -> Bool {
        guard board.column(for: after.status).triggersChat,
              after.sessionKey == nil,
              after.attentionReason == nil,
              !after.isQueued,
              after.assignedDeviceId == nil || after.assignedDeviceId == cloudDeviceID
        else { return false }
        guard let before else { return true }
        return !board.column(for: before.status).triggersChat
    }

    /// Starts the runs a cloud pull handed this Mac, each through the
    /// first-come, first-served claim in `startTask`.
    func startRemotelyMovedTasks(_ taskIds: [UUID]) {
        for id in taskIds {
            guard var task = task(id: id),
                  !dispatchingTaskIds.contains(id),
                  !isAgentRunning(for: task)
            else { continue }
            if !task.agent.isAssigned {
                task.agent = defaultTaskAgent()
                updateBoard(task.projectId) { board in
                    guard let index = board.tasks.firstIndex(where: { $0.id == id }) else { return }
                    board.tasks[index].agent = task.agent
                }
            }
            Task { await startTask(task) }
        }
    }
}
