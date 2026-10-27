import AppKit
import Foundation
import os
import RxAuthSwift
import RxCodeCore

/// The linked Autopilot project no longer answers for this account.
struct CloudProjectUnavailable: LocalizedError {
    var errorDescription: String? {
        String(localized: "This cloud project was deleted or you no longer have access to it. Choose Make Local Only to keep its tasks on this Mac.")
    }
}

/// The current step of a project's board sync. This is transient UI state;
/// the board's last successful sync and error remain in `CloudBoardSyncState`.
enum CloudProjectSyncPhase: Int {
    case fetchingBoard
    case syncingStories
    case syncingTasks
    case publishingFilters
    case savingChanges

    var fractionCompleted: Double { Double(rawValue) / 5 }

    var progressText: String {
        switch self {
        case .fetchingBoard: String(localized: "Fetching cloud board (step 1 of 5)")
        case .syncingStories: String(localized: "Syncing stories (step 2 of 5)")
        case .syncingTasks: String(localized: "Syncing tasks (step 3 of 5)")
        case .publishingFilters: String(localized: "Publishing Swift filters (step 4 of 5)")
        case .savingChanges: String(localized: "Finishing sync (step 5 of 5)")
        }
    }
}

/// Local and cloud projects.
///
/// A project is local by default: its task board lives only in
/// `task_board/<id>.json` on this Mac. A cloud project also names an Autopilot
/// project (`Project.cloudId`), and its stories and tasks sync through
/// Autopilot to every device signed in to the same account.
///
/// Sync is a three-way merge per story and task: the local fields, the remote
/// fields, and the fields both agreed on at the last sync
/// (`TaskBoard.cloudSync`). Whichever side changed wins; when both did, the
/// newer edit wins. Agent settings, runs, and attachments stay on the device.
extension AppState {

    /// How often cloud boards are pulled while signed in.
    static let cloudSyncPollInterval: Duration = .seconds(30)
    /// The cloud project list is refreshed every this many polls.
    static let cloudProjectListRefreshEvery = 4

    /// A stable, account-specific ID avoids taking over an old account's registration.
    var cloudDeviceID: String {
        let account = rxAuth.user?.id ?? "unknown"
        let key = "autopilot.deviceID.\(account)"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - Reads

    /// The Autopilot project a local project syncs with, once the project
    /// list has loaded.
    func cloudProject(for project: Project) -> CloudProject? {
        guard let cloudId = project.cloudId else { return nil }
        return cloudProjects.first { $0.id == cloudId }
    }

    /// Cloud projects not yet opened on this Mac.
    var unopenedCloudProjects: [CloudProject] {
        let linked = Set(projects.compactMap(\.cloudId))
        return cloudProjects
            .filter { !linked.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Unopened cloud projects shown on the Tasks overview.
    var visibleUnopenedCloudProjects: [CloudProject] {
        unopenedCloudProjects.filter { !hiddenCloudProjectIds.contains($0.id) }
    }

    /// Unopened cloud projects the user hid from the Tasks overview.
    var hiddenUnopenedCloudProjects: [CloudProject] {
        unopenedCloudProjects.filter { hiddenCloudProjectIds.contains($0.id) }
    }

    func setCloudProject(_ cloudId: String, hidden: Bool) {
        if hidden {
            hiddenCloudProjectIds.insert(cloudId)
        } else {
            hiddenCloudProjectIds.remove(cloudId)
        }
    }

    func showAllHiddenCloudProjects() {
        hiddenCloudProjectIds.removeAll()
    }

    /// The last sync error for a cloud project's board, if any.
    func cloudSyncError(for projectId: UUID) -> String? {
        taskBoards[projectId]?.cloudSync?.lastError
    }

    func cloudLastSyncedAt(for projectId: UUID) -> Date? {
        taskBoards[projectId]?.cloudSync?.lastSyncedAt
    }

    // MARK: - Polling

    /// Starts the background loop that keeps cloud boards current. Safe to
    /// call more than once; it no-ops while signed out.
    func startCloudProjectSync() {
        guard cloudSyncPollTask == nil else { return }
        cloudSyncPollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isSignedIn {
                    if tick % Self.cloudProjectListRefreshEvery == 0 {
                        await self.refreshCloudProjects()
                    }
                    self.syncAllCloudBoards()
                }
                tick += 1
                try? await Task.sleep(for: Self.cloudSyncPollInterval)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncAllCloudBoards() }
        }
    }

    /// Fetches the account's cloud projects and pulls every cloud board.
    /// Called on sign-in and from the Tasks page's refresh action.
    func refreshCloudProjectsAndBoards() async {
        await refreshCloudProjects()
        syncAllCloudBoards()
    }

    func refreshCloudProjects() async {
        guard isSignedIn else {
            clearCloudProjectState()
            return
        }
        do {
            cloudProjects = try await projectCloud.listProjects()
            do {
                try await projectCloud.registerDevice(id: cloudDeviceID, name: Host.current().localizedName ?? "Mac")
            } catch {
                logger.warning("Could not register cloud laptop: \(error.localizedDescription, privacy: .public)")
            }
            if let devices = try? await projectCloud.listDevices() {
                cloudDevices = devices
            }
            hasLoadedCloudProjects = true
        } catch {
            logger.error("Failed to list cloud projects: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the account's cloud project list on sign-out. Linked projects
    /// keep their `cloudId` and resume syncing on the next sign-in.
    func clearCloudProjectState() {
        cloudProjects = []
        cloudDevices = []
        hasLoadedCloudProjects = false
        for task in cloudSyncDebounceTasks.values { task.cancel() }
        cloudSyncDebounceTasks = [:]
        cloudSyncPhaseByProjectId = [:]
    }

    func syncAllCloudBoards() {
        guard isSignedIn else { return }
        for project in projects where project.isCloud {
            scheduleCloudBoardSync(for: project.id, delay: .zero)
        }
    }

    // MARK: - Scheduling

    /// Queues a sync of one project's board. Local edits call this through
    /// `setTaskBoard`, debounced so a burst of edits is sent together.
    func scheduleCloudBoardSync(for projectId: UUID, delay: Duration = .milliseconds(1500)) {
        guard isSignedIn, projects.contains(where: { $0.id == projectId && $0.isCloud }) else { return }
        cloudSyncDebounceTasks[projectId]?.cancel()
        cloudSyncDebounceTasks[projectId] = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.cloudSyncDebounceTasks[projectId] = nil
            self.runCloudBoardSync(for: projectId)
        }
    }

    /// Explicit user action releases the persisted publication failure latch.
    func retryCloudBoardSync(for projectId: UUID) {
        var board = taskBoard(for: projectId)
        board.cloudSync?.filterPublicationError = nil
        board.cloudSync?.lastError = nil
        setTaskBoard(board, for: projectId, fromCloud: true)
        scheduleCloudBoardSync(for: projectId, delay: .zero)
    }

    /// Runs one sync at a time per project; a request made while one is in
    /// flight runs once more when it finishes.
    private func runCloudBoardSync(for projectId: UUID) {
        guard cloudSyncTasks[projectId] == nil else {
            cloudSyncRerunProjectIds.insert(projectId)
            return
        }
        cloudSyncingProjectIds.insert(projectId)
        cloudSyncPhaseByProjectId[projectId] = .fetchingBoard
        cloudSyncTasks[projectId] = Task { [weak self] in
            guard let self else { return }
            await self.syncCloudBoard(projectId: projectId)
            self.cloudSyncTasks[projectId] = nil
            if self.cloudSyncRerunProjectIds.remove(projectId) != nil {
                self.runCloudBoardSync(for: projectId)
            } else {
                self.cloudSyncingProjectIds.remove(projectId)
                self.cloudSyncPhaseByProjectId[projectId] = nil
            }
        }
    }

    // MARK: - Local ↔ cloud

    /// Turns a local project into a cloud project. Links the Autopilot
    /// project that already tracks the same GitHub repository, or creates a
    /// new one, then uploads the board.
    func enableCloudSync(for projectId: UUID) async throws {
        guard isSignedIn else { throw AutopilotService.ServiceError.notAuthenticated }
        guard let project = projects.first(where: { $0.id == projectId }), !project.isCloud else { return }
        if !hasLoadedCloudProjects {
            await refreshCloudProjects()
        }
        let linked = Set(projects.compactMap(\.cloudId))
        let cloud: CloudProject
        if let match = cloudProjects.first(where: { $0.matchesRepository(project.gitHubRepo) && !linked.contains($0.id) }) {
            cloud = match
        } else {
            cloud = try await projectCloud.createProject(name: project.name)
            cloudProjects.append(cloud)
        }
        await linkProject(projectId, toCloudProject: cloud.id)
    }

    /// Makes a cloud project local to this Mac again. Its board stays here
    /// as it is; the Autopilot project and other devices are not touched.
    func disableCloudSync(for projectId: UUID) async {
        guard let index = projects.firstIndex(where: { $0.id == projectId }), projects[index].isCloud else { return }
        cloudSyncDebounceTasks.removeValue(forKey: projectId)?.cancel()
        cloudSyncTasks.removeValue(forKey: projectId)?.cancel()
        cloudSyncRerunProjectIds.remove(projectId)
        cloudSyncingProjectIds.remove(projectId)
        cloudSyncPhaseByProjectId[projectId] = nil
        projects[index].cloudId = nil
        await saveProjectList()
        var board = taskBoard(for: projectId)
        board.cloudSync = nil
        setTaskBoard(board, for: projectId, fromCloud: true)
    }

    /// Adds a new project from a folder, optionally as a cloud project.
    @discardableResult
    func createProject(name: String, folder: URL, cloud: Bool, in window: WindowState) async throws -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGitRepo = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        let gitHubRepo = isGitRepo ? detectGitHubOwnerRepo(at: folder.path) : nil
        guard let project = await addAndSelectProject(
            name: trimmed.isEmpty ? folder.lastPathComponent : trimmed,
            path: folder.path,
            gitHubRepo: gitHubRepo,
            in: window
        ) else { return nil }
        if cloud && !project.isCloud {
            try await enableCloudSync(for: project.id)
        }
        return projects.first { $0.id == project.id }
    }

    /// Opens a cloud project on this Mac in `folder`, then pulls its board.
    /// A project already added from that folder is linked instead.
    @discardableResult
    func openCloudProject(_ cloud: CloudProject, folder: URL, in window: WindowState) async -> Project? {
        if let existing = projects.first(where: { $0.path == folder.path }) {
            if existing.cloudId != cloud.id {
                if existing.isCloud { await disableCloudSync(for: existing.id) }
                await linkProject(existing.id, toCloudProject: cloud.id)
            }
            return projects.first { $0.id == existing.id }
        }
        let isGitRepo = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        let gitHubRepo = (isGitRepo ? detectGitHubOwnerRepo(at: folder.path) : nil) ?? cloud.repositoryFullName
        let name = cloud.type == "github"
            ? (cloud.repositoryFullName?.split(separator: "/").last.map(String.init) ?? cloud.title)
            : cloud.title
        guard let project = await addAndSelectProject(name: name, path: folder.path, gitHubRepo: gitHubRepo, in: window) else {
            return nil
        }
        await linkProject(project.id, toCloudProject: cloud.id)
        return projects.first { $0.id == project.id }
    }

    /// Links an existing local project to a cloud project and merges the two
    /// boards on the first sync.
    func linkProject(_ projectId: UUID, toCloudProject cloudId: String) async {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[index].cloudId = cloudId
        await saveProjectList()
        await ensureTaskBoardLoaded(for: projectId)
        var board = taskBoard(for: projectId)
        board.cloudSync = CloudBoardSyncState()
        setTaskBoard(board, for: projectId, fromCloud: true)
        scheduleCloudBoardSync(for: projectId, delay: .zero)
    }

    private func saveProjectList() async {
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Board sync

    /// Exchanges one board's changes with Autopilot.
    ///
    /// Every step writes the board back to `taskBoards` right away, so an edit
    /// made while a request is in flight sees the latest links and is picked
    /// up by the next run. The board is persisted once at the end.
    func syncCloudBoard(projectId: UUID) async {
        guard isSignedIn,
              let cloudId = projects.first(where: { $0.id == projectId })?.cloudId
        else { return }
        await ensureTaskBoardLoaded(for: projectId)

        var sync = taskBoard(for: projectId).cloudSync ?? CloudBoardSyncState()
        var remoteStarts: [UUID] = []
        do {
            let remote: CloudRemoteBoard
            do {
                remote = try await projectCloud.board(projectId: cloudId)
            } catch where ProjectCloudService.isNotFound(error) {
                // Deleted in Autopilot, or this account lost access. Keep the
                // link and the local board; the user can make it local.
                throw CloudProjectUnavailable()
            }
            guard isCloudLinked(projectId, to: cloudId) else { return }
            cloudSyncPhaseByProjectId[projectId] = .syncingStories
            try await syncStories(remote.stories, cloudId: cloudId, projectId: projectId, sync: &sync)
            cloudSyncPhaseByProjectId[projectId] = .syncingTasks
            try await syncTasks(remote.tasks, cloudId: cloudId, projectId: projectId, sync: &sync, remoteStarts: &remoteStarts)
            try await syncSavedViews(cloudId: cloudId, projectId: projectId, sync: &sync)
            cloudSyncPhaseByProjectId[projectId] = .savingChanges
            sync.lastSyncedAt = Date()
            sync.lastError = sync.filterPublicationError
        } catch {
            logger.error("Cloud sync failed: \(error.localizedDescription, privacy: .public)")
            sync.lastError = error.localizedDescription
        }

        guard isCloudLinked(projectId, to: cloudId) else { return }
        editCloudBoard(projectId, cloudId: cloudId, sync: sync)
        setTaskBoard(taskBoard(for: projectId), for: projectId, fromCloud: true)
        startRemotelyMovedTasks(remoteStarts)
    }

    private func syncSavedViews(cloudId: String, projectId: UUID, sync: inout CloudBoardSyncState) async throws {
        sync.filterPublicationError = nil
        cloudSyncPhaseByProjectId[projectId] = .publishingFilters
        var board = taskBoard(for: projectId)
        let originalViews = board.savedViews
        let account = rxAuth.user?.id
        for index in board.savedViews.indices {
            guard let source = board.savedViews[index].filterScript, board.savedViews[index].hasFilterScript else {
                board.savedViews[index].filterSnapshot = nil
                continue
            }
            let outcome = await taskFilterEvaluator.evaluate(script: source, input: TaskFilterScript.input(for: board))
            guard isSignedIn, rxAuth.user?.id == account, isCloudLinked(projectId, to: cloudId),
                  taskBoard(for: projectId).savedViews == originalViews else {
                scheduleCloudBoardSync(for: projectId, delay: .zero)
                return
            }
            switch outcome {
            case .selection(let selection):
                board.savedViews[index].filterSnapshot = TaskFilterSnapshot(source: source,
                    tasks: selection.taskIds.map(\.uuidString).sorted(), stories: selection.storyIds.map(\.uuidString).sorted())
            case .failure(let message):
                board.savedViews[index].filterSnapshot = nil
                sync.filterPublicationError = message
            }
        }
        editCloudBoard(projectId, cloudId: cloudId, sync: sync) { $0.savedViews = board.savedViews }
        // A conflict is retried from a fresh revision; never blindly replace
        // changes made by the phone while this Mac was uploading.
        for attempt in 0..<3 {
            guard let remote = try await projectCloud.savedViews(projectId: cloudId) else {
                if taskBoard(for: projectId).savedViews.contains(where: \.hasFilterScript) {
                    throw AutopilotService.ServiceError.apiError(404, "Update the Flowcy server to publish Swift filters.")
                }
                return
            }
            guard isCloudLinked(projectId, to: cloudId) else { return }
            let local = taskBoard(for: projectId).savedViews.map { CloudSavedView(view: $0, sync: sync) }
            let merged = CloudSavedViews.merging(local: local, base: sync.savedViewsBase, remote: remote.views)
            do {
                _ = merged != remote.views
                    ? try await projectCloud.saveViews(CloudSavedViews(views: merged, revision: remote.revision), projectId: cloudId)
                    : remote
                guard isCloudLinked(projectId, to: cloudId) else { return }
                // Preserve edits made during the upload for the next sync.
                let latest = taskBoard(for: projectId).savedViews.map { CloudSavedView(view: $0, sync: sync) }
                let applied = CloudSavedViews.merging(local: latest, base: local, remote: merged)
                sync.savedViewsBase = merged
                editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                    board.savedViews = applied.map { $0.localView(sync: sync) }
                }
                return
            } catch where sync.filterPublicationError == nil && ProjectCloudService.isConflict(error) && attempt < 2 { continue }
        }
    }

    private func isCloudLinked(_ projectId: UUID, to cloudId: String) -> Bool {
        projects.first(where: { $0.id == projectId })?.cloudId == cloudId
    }

    /// Applies one sync step to the in-memory board together with the
    /// updated links. Skipped when the project was unlinked mid-sync.
    private func editCloudBoard(
        _ projectId: UUID,
        cloudId: String,
        sync: CloudBoardSyncState,
        _ body: (inout TaskBoard) -> Void = { _ in }
    ) {
        guard isCloudLinked(projectId, to: cloudId) else { return }
        var board = taskBoard(for: projectId)
        body(&board)
        board.cloudSync = sync
        taskBoards[projectId] = board
    }

    private func syncStories(
        _ remoteStories: [CloudRemoteStory],
        cloudId: String,
        projectId: UUID,
        sync: inout CloudBoardSyncState
    ) async throws {
        let remoteById = Dictionary(remoteStories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Linked stories: deletions on either side, then the three-way merge.
        for (localId, link) in sync.stories {
            let board = taskBoard(for: projectId)
            let local = board.story(id: localId)
            guard let remote = remoteById[link.remoteId] else {
                sync.stories[localId] = nil
                editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                    board.stories.removeAll { $0.id == localId }
                    for index in board.tasks.indices where board.tasks[index].storyId == localId {
                        board.tasks[index].storyId = nil
                    }
                }
                continue
            }
            guard let local else {
                try await projectCloud.deleteStory(projectId: cloudId, storyId: link.remoteId)
                sync.stories[localId] = nil
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
                continue
            }
            let localFields = board.cloudFields(for: local)
            switch CloudMergeDecision.decide(
                local: localFields,
                base: link.base,
                remote: remote.fields,
                localIsNewer: local.updatedAt > (remote.updatedAt ?? .distantPast)
            ) {
            case .inSync:
                sync.stories[localId]?.base = remote.fields
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            case .push:
                let updated = try await projectCloud.updateStory(projectId: cloudId, storyId: link.remoteId, fields: localFields)
                sync.stories[localId]?.base = updated.fields
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            case .pull:
                sync.stories[localId]?.base = remote.fields
                editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                    guard let index = board.stories.firstIndex(where: { $0.id == localId }) else { return }
                    board.stories[index] = board.applying(remote.fields, to: board.stories[index], updatedAt: remote.updatedAt)
                }
            }
        }

        // New on this Mac: upload.
        for story in taskBoard(for: projectId).stories where sync.stories[story.id] == nil {
            let fields = taskBoard(for: projectId).cloudFields(for: story)
            guard !fields.title.isEmpty else { continue }
            let created = try await projectCloud.createStory(projectId: cloudId, fields: fields)
            sync.stories[story.id] = CloudItemLink(remoteId: created.id, base: created.fields)
            editCloudBoard(projectId, cloudId: cloudId, sync: sync)
        }

        // New in the cloud: add locally.
        let linkedRemote = Set(sync.stories.values.map(\.remoteId))
        for remote in remoteStories where !linkedRemote.contains(remote.id) {
            let localId = UUID()
            sync.stories[localId] = CloudItemLink(remoteId: remote.id, base: remote.fields)
            editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                let story = ProjectStory(id: localId, projectId: projectId, title: remote.fields.title)
                board.stories.append(board.applying(remote.fields, to: story, updatedAt: remote.updatedAt))
            }
        }
    }

    private func syncTasks(
        _ remoteTasks: [CloudRemoteTask],
        cloudId: String,
        projectId: UUID,
        sync: inout CloudBoardSyncState,
        remoteStarts: inout [UUID]
    ) async throws {
        // A board pulled for the first time only mirrors what is already
        // there; runs start for cards moved after that.
        let watchesMoves = sync.lastSyncedAt != nil
        let remoteById = Dictionary(remoteTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Deletions on either side.
        for (localId, link) in sync.tasks {
            let exists = taskBoard(for: projectId).tasks.contains { $0.id == localId }
            if remoteById[link.remoteId] == nil {
                sync.tasks[localId] = nil
                editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                    board.tasks.removeAll { $0.id == localId }
                    for index in board.tasks.indices {
                        board.tasks[index].parentTaskIds.removeAll { $0 == localId }
                    }
                }
                clearParentLinks(to: [localId], outside: projectId)
            } else if !exists {
                try await projectCloud.deleteTask(projectId: cloudId, taskId: link.remoteId)
                sync.tasks[localId] = nil
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            }
        }

        // New in the cloud: add placeholders first so parent links between
        // new tasks resolve, then fill them in below as pulls.
        let linkedRemote = Set(sync.tasks.values.map(\.remoteId))
        var pulledIds: [UUID: CloudRemoteTask] = [:]
        for remote in remoteTasks where !linkedRemote.contains(remote.id) {
            let localId = UUID()
            pulledIds[localId] = remote
            sync.tasks[localId] = CloudItemLink(remoteId: remote.id, base: remote.fields)
        }
        if !pulledIds.isEmpty {
            var created: [UUID] = []
            editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                for (localId, remote) in pulledIds {
                    let placeholder = ProjectTask(
                        id: localId,
                        projectId: projectId,
                        title: remote.fields.title,
                        status: board.localStatus(forCloud: remote.fields.status, current: nil)
                    )
                    let task = board.applying(remote.fields, to: placeholder, sync: sync, updatedAt: remote.updatedAt)
                    board.tasks.append(task)
                    if watchesMoves, remoteMoveStartsRun(from: nil, to: task, board: board) {
                        created.append(localId)
                    }
                }
            }
            remoteStarts.append(contentsOf: created)
        }

        // New on this Mac: upload parents before their children, so each
        // child is created with its parent's Autopilot id.
        var pending = taskBoard(for: projectId).tasks.filter {
            sync.tasks[$0.id] == nil && !CloudText.title($0.title).isEmpty
        }
        while !pending.isEmpty {
            let pendingIds = Set(pending.map(\.id))
            var ready = pending.filter { task in
                guard let parent = task.parentTaskId else { return true }
                return !pendingIds.contains(parent)
            }
            if ready.isEmpty { ready = pending }  // A cycle: send without the link.
            for task in ready {
                guard let current = taskBoard(for: projectId).tasks.first(where: { $0.id == task.id }) else { continue }
                let fields = taskBoard(for: projectId).cloudFields(for: current, sync: sync)
                let created = try await projectCloud.createTask(projectId: cloudId, fields: fields)
                sync.tasks[task.id] = CloudItemLink(remoteId: created.id, base: created.fields)
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            }
            let readyIds = Set(ready.map(\.id))
            pending.removeAll { readyIds.contains($0.id) }
        }

        // Linked tasks: three-way merge. Autopilot appends new tasks to the
        // end of a column, so fresh uploads come back through here with their
        // local sort order.
        for (localId, link) in sync.tasks where pulledIds[localId] == nil {
            guard let local = taskBoard(for: projectId).tasks.first(where: { $0.id == localId }) else { continue }
            guard let remote = remoteById[link.remoteId] else {
                // Uploaded this run: compare with what the server stored.
                let localFields = taskBoard(for: projectId).cloudFields(for: local, sync: sync)
                if localFields != link.base {
                    let updated = try await projectCloud.updateTask(projectId: cloudId, taskId: link.remoteId, fields: localFields)
                    sync.tasks[localId]?.base = updated.fields
                    editCloudBoard(projectId, cloudId: cloudId, sync: sync)
                }
                continue
            }
            let board = taskBoard(for: projectId)
            let localFields = board.cloudFields(for: local, sync: sync)
            // An agent run owns the column of its task; never pull a status
            // over it.
            let isLocked = board.isStatusLocked(local)
            let decision = CloudMergeDecision.decide(
                local: localFields,
                base: link.base,
                remote: remote.fields,
                localIsNewer: isLocked || local.updatedAt > (remote.updatedAt ?? .distantPast)
            )
            switch decision {
            case .inSync:
                sync.tasks[localId]?.base = remote.fields
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            case .push:
                let updated = try await projectCloud.updateTask(projectId: cloudId, taskId: link.remoteId, fields: localFields)
                sync.tasks[localId]?.base = updated.fields
                editCloudBoard(projectId, cloudId: cloudId, sync: sync)
            case .pull:
                sync.tasks[localId]?.base = remote.fields
                let linkState = sync
                var moved = false
                editCloudBoard(projectId, cloudId: cloudId, sync: sync) { board in
                    guard let index = board.tasks.firstIndex(where: { $0.id == localId }) else { return }
                    let before = board.tasks[index]
                    var pulled = board.applying(remote.fields, to: before, sync: linkState, updatedAt: remote.updatedAt)
                    if isLocked { pulled.status = before.status }
                    board.tasks[index] = pulled
                    moved = watchesMoves && !isLocked && remoteMoveStartsRun(from: before, to: pulled, board: board)
                }
                if moved { remoteStarts.append(localId) }
            }
        }
    }
}
