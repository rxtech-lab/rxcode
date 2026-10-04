import Foundation
import RxCodeCore
import RxCodeSync

extension MobileAppState {
    var taskProjects: [Project] { usesCloudTasks ? cloudTaskProjects : projects }
    var taskSnapshots: [UUID: MobileTaskBoardSnapshot] { usesCloudTasks ? cloudTaskBoards : taskBoardsByProject }

    func clearCloudTasks() {
        cloudTaskProjects = []
        cloudTaskBoards = [:]
        deferredCloudTaskBoardSnapshots = [:]
    }

    func refreshCloudTaskProjects() async throws {
        guard let cloud = taskCloud, cloud.isSignedIn else { throw AutopilotRemoteError.server("Sign in to view your cloud projects.") }
        await cloud.refresh()
        guard cloud.isSignedIn else { clearCloudTasks(); return }
        if let error = cloud.error { throw AutopilotRemoteError.server(error) }
        cloudTaskProjects = cloud.projects.map { remote in
            let id = cloudTaskProjects.first { $0.cloudId == remote.id }?.id ?? UUID(uuidString: remote.id) ?? UUID()
            return Project(id: id, name: remote.title, path: "", gitHubRepo: remote.repositoryFullName, cloudId: remote.id)
        }
        let ids = Set(cloudTaskProjects.map(\.id))
        cloudTaskBoards = cloudTaskBoards.filter { ids.contains($0.key) }
    }

    /// The board views use one command path; only the storage transport changes.
    func cloudTaskBoardCall(_ request: TaskBoardRequestPayload) async throws -> TaskBoardResultPayload {
        guard let cloud = taskCloud, cloud.isSignedIn,
              let remoteID = cloudTaskProjects.first(where: { $0.id == request.projectID })?.cloudId else {
            throw AutopilotRemoteError.server("Sign in and refresh this project before editing it.")
        }
        var board = cloudTaskBoards[request.projectID]?.board ?? TaskBoard()
        let viewsKey = cloud.accountID.map { "cloudTaskViews.\($0).\(remoteID)" }
        if cloudTaskBoards[request.projectID] == nil, let viewsKey,
           let data = UserDefaults.standard.data(forKey: viewsKey),
           let views = try? JSONDecoder().decode([TaskSavedView].self, from: data) {
            board.savedViews = views
        }
        var sync = board.cloudSync ?? CloudBoardSyncState()
        switch request.operation {
        case .fetch:
            try await cloud.loadBoard(remoteID)
        case .upsertTask:
            guard var task = request.task else { throw cloudTaskInvalidRequest() }
            if task.parentTaskIds.contains(where: { !board.canLinkTask(task.id, to: $0) }) {
                throw AutopilotRemoteError.server("This parent would create a task dependency cycle.")
            }
            if !board.tasks.contains(where: { $0.id == task.id }) {
                task.sortIndex = board.appendSortIndex(for: task.status)
            }
            let row = try await cloud.saveTask(board.cloudFields(for: task, sync: sync), id: sync.taskRemoteId(task.id), projectID: remoteID)
            sync.tasks[task.id] = CloudItemLink(remoteId: row.id, base: row.fields)
        case .moveTask:
            guard let id = request.taskID, var task = board.tasks.first(where: { $0.id == id }),
                  let status = request.status, let remoteTaskID = sync.taskRemoteId(id) else { throw cloudTaskInvalidRequest() }
            task.status = status
            task.sortIndex = request.sortIndex ?? board.appendSortIndex(for: status)
            try await cloud.saveTask(board.cloudFields(for: task, sync: sync), id: remoteTaskID, projectID: remoteID)
        case .deleteTask:
            guard let id = sync.taskRemoteId(request.taskID) else { throw cloudTaskInvalidRequest() }
            try await cloud.deleteTask(id, projectID: remoteID)
        case .upsertStory:
            guard let story = request.story else { throw cloudTaskInvalidRequest() }
            let row = try await cloud.saveStory(board.cloudFields(for: story), id: sync.storyRemoteId(story.id), projectID: remoteID)
            sync.stories[story.id] = CloudItemLink(remoteId: row.id, base: row.fields)
        case .deleteStory:
            guard let id = sync.storyRemoteId(request.storyID) else { throw cloudTaskInvalidRequest() }
            try await cloud.deleteStory(id, projectID: remoteID)
        case .upsertView:
            // Saved filters are local presentation preferences, as on the Mac.
            guard let view = request.view else { throw cloudTaskInvalidRequest() }
            board.upsertSavedView(view)
            if let viewsKey {
                UserDefaults.standard.set(try JSONEncoder().encode(board.savedViews), forKey: viewsKey)
            }
        case .quickAddTask, .followUp, .fetchRuns:
            throw AutopilotRemoteError.server("Connect to a Mac to use its agent and task runs.")
        }
        guard cloud.isSignedIn else { throw CancellationError() }
        board.cloudSync = sync
        if let remote = cloud.boards[remoteID] {
            board = board.replacingCloudRows(remote, projectID: request.projectID)
        }
        let snapshot = MobileTaskBoardSnapshot(projectID: request.projectID, board: board)
        storeTaskBoardSnapshot(snapshot, cloud: true)
        return TaskBoardResultPayload(clientRequestID: request.clientRequestID, projectID: request.projectID, ok: true, snapshot: snapshot, taskID: request.task?.id ?? request.taskID)
    }

    private func cloudTaskInvalidRequest() -> AutopilotRemoteError {
        .server("This item is no longer available. Refresh the task board and try again.")
    }
}
