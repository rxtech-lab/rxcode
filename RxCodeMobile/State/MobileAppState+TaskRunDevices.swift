import Foundation
import RxCodeCore
import RxCodeSync

/// The paired Mac a task was run on from this phone, so tapping its card can
/// reopen the session there.
struct MobileTaskRunLink: Codable, Equatable {
    /// `PairedDesktop.id` of the Mac running the task.
    var desktopID: String
    var desktopName: String
    /// The Mac's own project and task IDs, which differ from a cloud board's.
    var projectID: UUID
    var taskID: UUID
    var sessionID: String?
    var startedAt: Date

    static let storageKey = "mobile.taskRunLinks"
    static let maxStored = 200

    static func loadAll() -> [String: MobileTaskRunLink] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let links = try? JSONDecoder().decode([String: MobileTaskRunLink].self, from: data)
        else { return [:] }
        return links
    }

    /// Persists the newest `maxStored` links.
    static func saveAll(_ links: [String: MobileTaskRunLink]) {
        let kept = links.count > maxStored
            ? Dictionary(uniqueKeysWithValues: links.sorted { $0.value.startedAt > $1.value.startedAt }.prefix(maxStored).map { ($0.key, $0.value) })
            : links
        guard let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// A move into a chat column waiting for the user to pick the Mac that runs it.
struct MobileTaskRunRequest: Identifiable {
    let id = UUID()
    let task: ProjectTask
    let status: TaskStatus
    var sortIndex: Double?
}

extension MobileAppState {
    static let lastRunDesktopKey = "mobile.lastRunDesktopID"

    // MARK: - Reads

    /// Cloud tasks are keyed by their Autopilot ID, since their local IDs are
    /// regenerated on every launch.
    func taskRunLinkKey(for task: ProjectTask) -> String? {
        guard usesCloudTasks else { return "desktop:\(task.id.uuidString)" }
        return taskSnapshots[task.projectId]?.board.cloudSync?.taskRemoteId(task.id).map { "cloud:\($0)" }
    }

    /// The run link a tap on the card follows: only while the task sits in a
    /// chat column and its Mac is still paired.
    func activeTaskRunLink(for task: ProjectTask) -> MobileTaskRunLink? {
        let board = taskBoard(for: task.projectId)
        guard board.column(for: board.resolvedStatus(of: task)).triggersChat,
              let link = taskRunLinkKey(for: task).flatMap({ taskRunLinks[$0] }),
              pairedDesktops.contains(where: { $0.id == link.desktopID })
        else { return nil }
        return link
    }

    /// The device a card shows it is running on: the Mac this phone ran it
    /// on, else, on a cloud board, the device that claimed its run. A
    /// teammate's Mac isn't registered on this account, so it has no name.
    func taskRunDeviceName(for task: ProjectTask) -> String? {
        if let link = activeTaskRunLink(for: task) { return link.desktopName }
        let board = taskBoard(for: task.projectId)
        guard usesCloudTasks,
              let owner = task.assignedDeviceId,
              board.column(for: board.resolvedStatus(of: task)).triggersChat
        else { return nil }
        return taskCloud?.devices.first { $0.id == owner }?.name ?? String(localized: "another device")
    }

    /// Whether moving `task` into `status` starts an agent run, so the Mac
    /// that runs it is picked first.
    func moveStartsRun(_ task: ProjectTask, to status: TaskStatus) -> Bool {
        let board = taskBoard(for: task.projectId)
        guard board.column(for: status).triggersChat,
              !board.column(for: board.resolvedStatus(of: task)).triggersChat,
              !pairedDesktops.isEmpty
        else { return false }
        return true
    }

    /// A Mac-backed board belongs to the active Mac, so only it can run that
    /// board's tasks. Cloud tasks can run on any paired Mac with the project.
    func canRunTasks(on desktop: PairedDesktop) -> Bool {
        usesCloudTasks || desktop.id == activePairedDesktop?.id
    }

    /// The last Mac picked for a run, else the active one.
    func defaultRunDesktop() -> PairedDesktop? {
        let candidates = pairedDesktops.filter(canRunTasks(on:))
        let last = UserDefaults.standard.string(forKey: Self.lastRunDesktopKey)
        return candidates.first { $0.id == last }
            ?? candidates.first { $0.id == activePairedDesktop?.id }
            ?? candidates.first
    }

    // MARK: - Running

    /// Moves `task` into chat column `status` on `desktop`, which starts its
    /// agent there, and remembers the Mac so the card can open the session.
    func runTask(_ task: ProjectTask, to status: TaskStatus, sortIndex: Double? = nil, on desktop: PairedDesktop, agent: TaskAgentConfig) async throws {
        UserDefaults.standard.set(desktop.id, forKey: Self.lastRunDesktopKey)
        if usesCloudTasks {
            try await runCloudTask(task, to: status, on: desktop, agent: agent)
            return
        }
        guard desktop.id == activePairedDesktop?.id else {
            throw AutopilotRemoteError.server(String(localized: "Switch to \(desktop.displayName) to run its tasks."))
        }
        try await moveTask(task, to: status, sortIndex: sortIndex, runAgent: agent)
        storeTaskRunLink(MobileTaskRunLink(
            desktopID: desktop.id,
            desktopName: desktop.displayName,
            projectID: task.projectId,
            taskID: task.id,
            sessionID: taskSessionID(task),
            startedAt: Date()
        ), for: task)
    }

    /// Asks `desktop` to run a cloud task. The Mac moves its own copy into a
    /// chat column and pushes the new status to the cloud.
    private func runCloudTask(_ task: ProjectTask, to status: TaskStatus, on desktop: PairedDesktop, agent: TaskAgentConfig) async throws {
        guard let remoteTaskID = taskSnapshots[task.projectId]?.board.cloudSync?.taskRemoteId(task.id),
              let cloudProjectID = cloudTaskProjects.first(where: { $0.id == task.projectId })?.cloudId
        else {
            throw AutopilotRemoteError.server(String(localized: "Refresh this project before running its tasks."))
        }
        try await activateDesktop(desktop)
        let result = try await desktopTaskBoardCall(TaskBoardRequestPayload(
            projectID: task.projectId,
            operation: .moveTask,
            taskID: task.id,
            status: status,
            runAgent: agent,
            cloudProjectID: cloudProjectID,
            cloudTaskID: remoteTaskID
        ))
        guard let localTaskID = result.taskID else { throw AutopilotRemoteError.emptyResponse }
        storeTaskRunLink(MobileTaskRunLink(
            desktopID: desktop.id,
            desktopName: desktop.displayName,
            projectID: result.projectID,
            taskID: localTaskID,
            sessionID: result.snapshot?.sessionID(for: localTaskID),
            startedAt: Date()
        ), for: task)

        // Show the card in its run column now; reload once the Mac has
        // pushed the change to the cloud.
        if var snapshot = cloudTaskBoards[task.projectId],
           let index = snapshot.board.tasks.firstIndex(where: { $0.id == task.id }) {
            snapshot.board.tasks[index].status = status
            snapshot.board.tasks[index].sortIndex = snapshot.board.appendSortIndex(for: status)
            cloudTaskBoards[task.projectId] = snapshot
        }
        let projectID = task.projectId
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.usesCloudTasks else { return }
            try? await self.loadTaskBoard(projectID: projectID)
        }
    }

    /// Makes `desktop` the active Mac and waits until its task sync is ready.
    func activateDesktop(_ desktop: PairedDesktop, timeout: Duration = .seconds(20)) async throws {
        if desktop.id != activePairedDesktop?.id {
            await switchPairedDesktop(desktop)
        }
        let deadline = ContinuousClock.now + timeout
        while !isDesktopTaskSyncReady {
            guard ContinuousClock.now < deadline else {
                throw AutopilotRemoteError.server(String(localized: "\(desktop.displayName) isn't reachable. Make sure RxCode is open on it."))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Opening the session

    /// Switches to the Mac running `task` and resolves its session there.
    /// Returns the session ID and the Mac's project ID.
    func openTaskRunSession(for task: ProjectTask) async throws -> (sessionID: String, projectID: UUID) {
        guard let key = taskRunLinkKey(for: task), var link = taskRunLinks[key] else {
            throw AutopilotRemoteError.server(String(localized: "This task wasn't run from this device."))
        }
        guard let desktop = pairedDesktops.first(where: { $0.id == link.desktopID }) else {
            throw AutopilotRemoteError.server(String(localized: "\(link.desktopName) is no longer paired."))
        }
        try await activateDesktop(desktop)
        var sessionID = taskBoardsByProject[link.projectID]?.sessionID(for: link.taskID)
        if sessionID == nil {
            try await desktopTaskBoardCall(TaskBoardRequestPayload(projectID: link.projectID, operation: .fetch))
            sessionID = taskBoardsByProject[link.projectID]?.sessionID(for: link.taskID) ?? link.sessionID
        }
        guard let sessionID else {
            throw AutopilotRemoteError.server(String(localized: "The session on \(link.desktopName) hasn't started yet. Try again in a moment."))
        }
        if link.sessionID != sessionID {
            link.sessionID = sessionID
            storeTaskRunLink(link, forKey: key)
        }
        return (sessionID, link.projectID)
    }

    // MARK: - Storage

    private func storeTaskRunLink(_ link: MobileTaskRunLink, for task: ProjectTask) {
        guard let key = taskRunLinkKey(for: task) else { return }
        storeTaskRunLink(link, forKey: key)
    }

    private func storeTaskRunLink(_ link: MobileTaskRunLink, forKey key: String) {
        taskRunLinks[key] = link
        MobileTaskRunLink.saveAll(taskRunLinks)
    }

    /// Records the session each linked task opened on the active Mac, as its
    /// board snapshots report them.
    func refreshTaskRunLinks(from snapshot: MobileTaskBoardSnapshot) {
        guard let desktopID = activePairedDesktop?.id else { return }
        var changed = false
        for (key, link) in taskRunLinks where link.desktopID == desktopID && link.projectID == snapshot.projectID {
            if let sessionID = snapshot.sessionID(for: link.taskID), sessionID != link.sessionID {
                taskRunLinks[key]?.sessionID = sessionID
                changed = true
            }
        }
        if changed { MobileTaskRunLink.saveAll(taskRunLinks) }
    }
}
