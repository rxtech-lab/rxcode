import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Archive

    func archiveSession(_ session: ChatSession, in window: WindowState) async {
        await setArchived(session, archived: true, in: window)
    }

    func unarchiveSession(_ session: ChatSession, in window: WindowState? = nil) async {
        if let window {
            await setArchived(session, archived: false, in: window)
        } else {
            await setArchivedNoWindow(session, archived: false)
        }
    }

    func setArchived(_ session: ChatSession, archived: Bool, in window: WindowState) async {
        // If the chat being archived is currently open in this window, swap to a
        // fresh session so the user isn't stranded staring at a now-hidden chat.
        if archived, window.currentSessionId == session.id {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }
        await setArchivedNoWindow(session, archived: archived)
    }

    func setArchivedNoWindow(_ session: ChatSession, archived: Bool) async {
        let now = Date()
        if let si = allSessionSummaries.firstIndex(where: { $0.id == session.id }) {
            allSessionSummaries[si].isArchived = archived
            allSessionSummaries[si].archivedAt = archived ? now : nil
            threadStore.upsert(allSessionSummaries[si])
        } else {
            _ = threadStore.setArchived(id: session.id, archived: archived, at: now)
        }
        await updateSessionMetadata(session) { s in
            s.isArchived = archived
            s.archivedAt = archived ? now : nil
        }
        scheduleMobileSnapshotBroadcast()
    }

    /// Retention window (days) after which a branch briefing is purged if its
    /// branch hasn't been observed locally or remotely. A branch deleted both
    /// places will simply stop being touched and age out.
    static let branchBriefingRetentionDays = 30

    /// Mark a branch as still alive on disk so its briefing isn't garbage-
    /// collected. Called from views that have just observed the branch via
    /// `git symbolic-ref` or similar.
    func touchBranchBriefing(projectId: UUID, branch: String) {
        threadStore.touchBranchBriefing(projectId: projectId, branch: branch)
    }

    /// Delete branch briefings for branches that haven't been seen for the
    /// retention window. Run once at app launch.
    func purgeStaleBranchBriefingsIfNeeded() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -Self.branchBriefingRetentionDays,
            to: Date()
        ) ?? Date()
        let purged = threadStore.purgeStaleBranchBriefings(olderThan: cutoff)
        guard !purged.isEmpty else { return }
        branchBriefingRevision &+= 1
        logger.info("Purged \(purged.count) stale branch briefings older than \(Self.branchBriefingRetentionDays) days")
    }

    /// Apply the auto-archive policy: archive non-pinned chats whose `updatedAt`
    /// is older than `archiveRetentionDays`. Run once at app launch.
    func autoArchiveExpiredSessionsIfNeeded() {
        guard autoArchiveEnabled else { return }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -archiveRetentionDays,
            to: Date()
        ) ?? Date()
        let archivedIds = threadStore.archiveStale(olderThan: cutoff)
        guard !archivedIds.isEmpty else { return }
        let idSet = Set(archivedIds)
        let now = Date()
        for idx in allSessionSummaries.indices where idSet.contains(allSessionSummaries[idx].id) {
            allSessionSummaries[idx].isArchived = true
            allSessionSummaries[idx].archivedAt = now
        }
        logger.info("Auto-archived \(archivedIds.count) chats older than \(self.archiveRetentionDays) days")
    }

    /// Apply the auto-delete policy: permanently delete archived, non-pinned
    /// chats whose `archivedAt` is older than `deleteRetentionDays`. Threads
    /// must be archived first — this never deletes active chats. Runs after
    /// `autoArchiveExpiredSessionsIfNeeded` at app launch.
    func autoDeleteExpiredSessionsIfNeeded() async {
        guard autoDeleteEnabled else { return }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -deleteRetentionDays,
            to: Date()
        ) ?? Date()
        let staleIds = Set(threadStore.staleArchivedIds(olderThan: cutoff))
        guard !staleIds.isEmpty else { return }

        let toDelete = allSessionSummaries.filter { staleIds.contains($0.id) }
        for summary in toDelete {
            let cwd = summary.worktreePath
                ?? projects.first(where: { $0.id == summary.projectId })?.path
            do {
                try await persistence.deleteSession(
                    projectId: summary.projectId,
                    sessionId: summary.id,
                    origin: summary.origin,
                    cwd: cwd
                )
            } catch {
                logger.error("Auto-delete: failed to remove session \(summary.id): \(error.localizedDescription)")
            }
        }

        allSessionSummaries.removeAll { staleIds.contains($0.id) }
        for id in staleIds {
            threadStore.delete(id: id)
            sessionStates.removeValue(forKey: id)
        }
        let snapshotIds = staleIds
        Task.detached(priority: .utility) { [searchService] in
            for id in snapshotIds { await searchService.removeThread(id: id) }
        }
        logger.info("Auto-deleted \(staleIds.count) archived chats older than \(self.deleteRetentionDays) days")
    }

    /// Persist a metadata-only edit (title, pin, etc.) routing by session
    /// origin. cliBacked sessions go to the sidecar; legacy sessions need the
    /// full message log to be re-saved alongside the change.
    /// `persistTitle` should be true only for explicit user renames; pin and
    /// other non-title edits leave the sidecar title untouched so it stays
    /// in sync with the CLI's first-message-derived label.

    // MARK: - Worktree

    /// Create a Git worktree for the chat and remember it on the session.
    /// Subsequent CLI invocations for this session will run in the worktree.
    func attachWorktree(branch: String, in window: WindowState) async throws {
        guard let project = window.selectedProject else {
            throw AppError.noProjectSelected
        }
        let baseRepo = URL(fileURLWithPath: project.path)
        let info = try await GitWorktreeService.shared.createWorktree(
            baseRepo: baseRepo,
            branch: branch
        )

        // New-chat view: no session yet. Park the worktree on the window so
        // it gets applied when sendPrompt allocates a session id.
        guard let sessionId = window.currentSessionId else {
            window.pendingWorktreePath = info.path.path
            window.pendingWorktreeBranch = info.branch
            return
        }

        // Update in-memory state
        sessionStates[sessionId, default: SessionStreamState()].worktreePath = info.path.path
        sessionStates[sessionId, default: SessionStreamState()].worktreeBranch = info.branch
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = info.path.path
            allSessionSummaries[idx].worktreeBranch = info.branch
            threadStore.upsert(allSessionSummaries[idx])
        }
        // Persist via sidecar meta
        let snap = allSessionSummaries.first(where: { $0.id == sessionId })
        let fallbackProvider = defaultModelSelection(for: project).provider
        let updated = (snap ?? ChatSession.Summary(
            id: sessionId, projectId: project.id, title: ChatSession.defaultTitle,
            createdAt: Date(), updatedAt: Date(), isPinned: false,
            agentProvider: sessionStates[sessionId]?.agentProvider ?? fallbackProvider,
            worktreePath: info.path.path, worktreeBranch: info.branch
        )).makeSession()
        await updateSessionMetadata(updated) { s in
            s.worktreePath = info.path.path
            s.worktreeBranch = info.branch
        }
    }

    /// Mobile new-thread flow: spawn the next thread on `branch` via a Git
    /// worktree, not by mutating the main project repo. Reuses an existing
    /// linked worktree for the branch when one is around; otherwise creates a
    /// fresh worktree off the existing branch. Falls back to leaving the
    /// pending pointer nil only when the branch is already checked out in the
    /// main repo (`git worktree add` would refuse), so the thread still spawns
    /// on the right branch without misrepresenting the project root as a
    /// worktree.
    func attachWorktreeForExistingBranch(_ branch: String, in window: WindowState) async throws {
        guard let project = window.selectedProject else {
            throw AppError.noProjectSelected
        }
        let baseRepo = URL(fileURLWithPath: project.path)

        let info = try await GitWorktreeService.shared.createWorktree(
            baseRepo: baseRepo,
            branch: branch
        )

        let isMainRepo = info.path.standardizedFileURL == baseRepo.standardizedFileURL
        let newPath: String? = isMainRepo ? nil : info.path.path
        let newBranch: String? = isMainRepo ? nil : info.branch

        guard let sessionId = window.currentSessionId else {
            window.pendingWorktreePath = newPath
            window.pendingWorktreeBranch = newBranch
            return
        }

        sessionStates[sessionId, default: SessionStreamState()].worktreePath = newPath
        sessionStates[sessionId, default: SessionStreamState()].worktreeBranch = newBranch
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = newPath
            allSessionSummaries[idx].worktreeBranch = newBranch
            threadStore.upsert(allSessionSummaries[idx])
        }
        if let snap = allSessionSummaries.first(where: { $0.id == sessionId }) {
            await updateSessionMetadata(snap.makeSession()) { s in
                s.worktreePath = newPath
                s.worktreeBranch = newBranch
            }
        }
    }

    /// Switch the chat to an existing branch.
    ///
    /// If the branch is already attached to a linked worktree, point the
    /// session at that worktree. Otherwise run `git checkout` in the project
    /// root and clear the session's worktree pointer.
    func switchToExistingBranch(_ branch: String, in window: WindowState) async throws {
        guard let project = window.selectedProject else {
            throw AppError.noProjectSelected
        }
        let baseRepo = URL(fileURLWithPath: project.path)

        let existingWorktree: GitWorktreeService.WorktreeInfo? = await {
            guard let list = try? await GitWorktreeService.shared.listWorktrees(baseRepo: baseRepo) else {
                return nil
            }
            // The main repo also appears in `worktree list`; skip it so the
            // project root takes the plain-checkout path.
            return list.first { $0.branch == branch && $0.path.standardizedFileURL != baseRepo.standardizedFileURL }
        }()

        let newPath: String?
        let newBranch: String?
        if let existingWorktree {
            newPath = existingWorktree.path.path
            newBranch = existingWorktree.branch
        } else {
            if let err = await GitHelper.checkout(branch: branch, at: project.path) {
                throw GitWorktreeService.WorktreeError.gitFailed(err)
            }
            newPath = nil
            newBranch = nil
        }

        guard let sessionId = window.currentSessionId else {
            window.pendingWorktreePath = newPath
            window.pendingWorktreeBranch = newBranch
            return
        }

        sessionStates[sessionId, default: SessionStreamState()].worktreePath = newPath
        sessionStates[sessionId, default: SessionStreamState()].worktreeBranch = newBranch
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = newPath
            allSessionSummaries[idx].worktreeBranch = newBranch
            threadStore.upsert(allSessionSummaries[idx])
        }
        if let snap = allSessionSummaries.first(where: { $0.id == sessionId }) {
            await updateSessionMetadata(snap.makeSession()) { s in
                s.worktreePath = newPath
                s.worktreeBranch = newBranch
            }
        }
    }

    /// Remove the worktree associated with the session (if any).
    /// `force = true` removes even with uncommitted changes.
    func detachWorktree(in window: WindowState, force: Bool = false) async throws {
        guard let sessionId = window.currentSessionId else { return }
        let path = sessionStates[sessionId]?.worktreePath
            ?? allSessionSummaries.first(where: { $0.id == sessionId })?.worktreePath
        guard let path else { return }
        try await GitWorktreeService.shared.removeWorktree(URL(fileURLWithPath: path), force: force)
        sessionStates[sessionId]?.worktreePath = nil
        sessionStates[sessionId]?.worktreeBranch = nil
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = nil
            allSessionSummaries[idx].worktreeBranch = nil
            threadStore.upsert(allSessionSummaries[idx])
        }
        if let snap = allSessionSummaries.first(where: { $0.id == sessionId }) {
            await updateSessionMetadata(snap.makeSession()) { s in
                s.worktreePath = nil
                s.worktreeBranch = nil
            }
        }
    }

    /// Returns the current effective working directory for the active chat —
    /// either the chat's worktree (if attached) or the project path.
    func effectiveCwd(in window: WindowState) -> String? {
        guard let project = window.selectedProject else { return nil }
        if let sid = window.currentSessionId {
            if let p = sessionStates[sid]?.worktreePath { return p }
            if let p = allSessionSummaries.first(where: { $0.id == sid })?.worktreePath { return p }
        }
        return project.path
    }

    func updateSessionMetadata(
        _ session: ChatSession,
        persistTitle: Bool = false,
        mutate: (inout ChatSession) -> Void
    ) async {
        let summary = allSessionSummaries.first(where: { $0.id == session.id }) ?? session.summary
        var updated: ChatSession = switch summary.origin {
        case .cliBacked:
            summary.makeSession()
        case .legacyRxCode, .codexAppServer, .acpAgent:
            persistence.loadLegacySessionSync(projectId: session.projectId, sessionId: session.id) ?? session
        }
        mutate(&updated)
        do { try await persistence.saveSession(updated, persistTitle: persistTitle) }
        catch { logger.error("Failed to save session metadata: \(error.localizedDescription)") }
    }

    func renameProject(_ project: Project, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = trimmed
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects after rename: \(error.localizedDescription)")
        }
    }

    func deleteProject(_ project: Project, in window: WindowState) async {
        // Switch away if the deleted project is currently selected
        if window.selectedProject?.id == project.id {
            let next = projects.first(where: { $0.id != project.id })
            if let next {
                selectProject(next, in: window)
            } else {
                window.selectedProject = nil
                window.currentSessionId = nil
            }
        }

        // Cascade: delete each session's stored messages (CLI jsonl, meta,
        // legacy json) before discarding the project itself. Without this the
        // jsonls remain on disk under the project's cwd and would resurface as
        // orphan sessions if the same path is added back as a project later.
        let projectSummaries = allSessionSummaries.filter { $0.projectId == project.id }
        for summary in projectSummaries {
            let cwd = summary.worktreePath ?? project.path
            do {
                try await persistence.deleteSession(
                    projectId: summary.projectId,
                    sessionId: summary.id,
                    origin: summary.origin,
                    cwd: cwd
                )
            } catch {
                logger.error("Failed to delete session \(summary.id) on project delete: \(error.localizedDescription)")
            }
            sessionStates.removeValue(forKey: summary.id)
        }

        // Remove all in-memory session summaries for this project
        threadStore.deleteAll(projectId: project.id)
        let projectId = project.id
        Task.detached(priority: .utility) { [searchService] in await searchService.removeProject(id: projectId) }
        Task.detached(priority: .utility) { [memoryService] in await memoryService.deleteAll(projectId: projectId) }
        allSessionSummaries.removeAll { $0.projectId == project.id }

        // Remove from projects list and persist
        projects.removeAll { $0.id == project.id }
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects after deletion: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ session: ChatSession, in window: WindowState) async {
        if window.currentSessionId == session.id {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }
        let summary = allSessionSummaries.first(where: { $0.id == session.id })
        let origin = summary?.origin ?? session.origin
        // Prefer the worktreePath used while writing the jsonl — otherwise the
        // CLI jsonl (stored under that cwd) is orphaned on disk and resurrects
        // on next reload. Fall back to the project's path, then the session's.
        let cwd = summary?.worktreePath
            ?? session.worktreePath
            ?? projects.first(where: { $0.id == session.projectId })?.path
        do {
            try await persistence.deleteSession(projectId: session.projectId, sessionId: session.id, origin: origin, cwd: cwd)
        } catch {
            logger.error("Failed to delete session: \(error.localizedDescription)")
        }
        allSessionSummaries.removeAll { $0.id == session.id }
        threadStore.delete(id: session.id)
        let deletedId = session.id
        Task.detached(priority: .utility) { [searchService] in await searchService.removeThread(id: deletedId) }
        sessionStates.removeValue(forKey: session.id)
    }

    func deleteAllSessions(projectId: UUID? = nil, archivedOnly: Bool = false, in window: WindowState) async {
        var toDelete: [ChatSession.Summary]
        if let projectId {
            toDelete = allSessionSummaries.filter { $0.projectId == projectId }
        } else {
            toDelete = allSessionSummaries
        }
        if archivedOnly {
            toDelete = toDelete.filter { $0.isArchived }
        }
        let ids = Set(toDelete.map(\.id))

        // Only disrupt the current window's stream if its session is actually
        // being deleted — otherwise a project-scoped delete would clobber an
        // unrelated streaming session.
        if let currentId = window.currentSessionId, ids.contains(currentId) {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }

        for summary in toDelete {
            let cwd = summary.worktreePath
                ?? projects.first(where: { $0.id == summary.projectId })?.path
            do {
                try await persistence.deleteSession(
                    projectId: summary.projectId,
                    sessionId: summary.id,
                    origin: summary.origin,
                    cwd: cwd
                )
            } catch {
                logger.error("Failed to delete session \(summary.id): \(error.localizedDescription)")
            }
        }

        allSessionSummaries.removeAll { ids.contains($0.id) }
        if archivedOnly {
            for id in ids {
                threadStore.delete(id: id)
            }
            let snapshotIds = ids
            Task.detached(priority: .utility) { [searchService] in
                for id in snapshotIds { await searchService.removeThread(id: id) }
            }
        } else {
            threadStore.deleteAll(projectId: projectId)
            if let projectId {
                Task.detached(priority: .utility) { [searchService] in await searchService.removeProject(id: projectId) }
            } else {
                let snapshotIds = ids
                Task.detached(priority: .utility) { [searchService] in
                    for id in snapshotIds { await searchService.removeThread(id: id) }
                }
            }
        }
        for id in ids {
            sessionStates.removeValue(forKey: id)
        }
    }

    func selectSession(id: String, in window: WindowState) {
        logger.info("[SelectSession] click sid=\(id, privacy: .public) currentSid=\(window.currentSessionId ?? "<nil>", privacy: .public) selectedProject=\(window.selectedProject?.id.uuidString ?? "<nil>", privacy: .public) summariesCount=\(self.allSessionSummaries.count)")
        guard window.currentSessionId != id else {
            if window.showingBriefing {
                window.showingBriefing = false
                window.requestInputFocus = true
                logger.info("[SelectSession] same sid, leaving briefing sid=\(id, privacy: .public)")
            } else {
                logger.info("[SelectSession] no-op: already current sid=\(id, privacy: .public)")
            }
            return
        }

        window.cancelSessionSwitchTask()

        if let summary = allSessionSummaries.first(where: { $0.id == id }),
           summary.projectId == window.selectedProject?.id
        {
            logger.info("[SelectSession] match in current project sid=\(id, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public) title=\(summary.title, privacy: .public)")
            let session = summary.makeSession()
            switchToSession(session, in: window)
            window.requestInputFocus = true
            window.setSessionSwitchTask(Task {
                guard !Task.isCancelled else { return }
                await didSwitchToSession(session)
            })
            return
        }

        // If it's a session from another project, switch the project as well
        guard let summary = allSessionSummaries.first(where: { $0.id == id }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else {
            logger.error("[SelectSession] summary or project missing for sid=\(id, privacy: .public)")
            return
        }

        logger.info("[SelectSession] cross-project switch sid=\(id, privacy: .public) toProject=\(project.id.uuidString, privacy: .public)")
        window.setSessionSwitchTask(Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            selectProject(project, in: window)
            guard !Task.isCancelled else { return }
            if let s = allSessionSummaries.first(where: { $0.id == id }) {
                let session = s.makeSession()
                if sessionStates[session.id] == nil,
                   let full = await persistence.loadFullSession(summary: s, cwd: project.path)
                {
                    logger.info("[SelectSession] cross-project preload ok sid=\(id, privacy: .public) messages=\(full.messages.count)")
                    switchToSession(full, messages: full.messages, in: window)
                } else {
                    logger.info("[SelectSession] cross-project preload empty sid=\(id, privacy: .public)")
                    switchToSession(session, in: window)
                }
                window.requestInputFocus = true
                await didSwitchToSession(session)
            }
        })
    }

    func addProject(_ project: Project) {
        guard !projects.contains(where: { $0.path == project.path }) else { return }
        projects.append(project)
        Task {
            do { try await persistence.saveProjects(projects) }
            catch { logger.error("Failed to save projects: \(error.localizedDescription)") }
        }
    }

}
