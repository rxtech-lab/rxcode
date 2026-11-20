import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    func handleMobileBranchOpRequest(_ request: BranchOpRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: "Project not found on desktop.",
                toHex: fromHex
            )
            return
        }

        if request.operation == .initGit {
            if let err = await GitHelper.initRepository(at: project.path) {
                await replyBranchOpResult(
                    request: request,
                    ok: false,
                    errorMessage: err,
                    toHex: fromHex
                )
                return
            }
            await replyBranchOpResult(request: request, ok: true, errorMessage: nil, toHex: fromHex)
            scheduleMobileSnapshotBroadcast()
            return
        }

        let trimmed = request.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: "Branch name is required.",
                toHex: fromHex
            )
            return
        }

        let window = WindowState()
        window.selectedProject = project

        do {
            switch request.operation {
            case .switchExisting:
                // Mobile's new-thread sheet expects each thread to spawn into
                // its own worktree — never `git checkout` against the project
                // root, since that would silently move main onto the picked
                // branch and skip the worktree entirely.
                try await attachWorktreeForExistingBranch(trimmed, in: window)
                updateMobilePendingWorktree(from: window, projectID: project.id)
            case .createNew:
                // Honor the mobile picker: worktree (default) keeps the main
                // checkout untouched; checkout creates the branch in the
                // project root and clears any parked worktree so the next
                // thread spawns there.
                if request.useWorktree ?? true {
                    try await attachWorktree(branch: trimmed, in: window)
                } else {
                    try await createBranchInPlace(branch: trimmed, in: window)
                }
                updateMobilePendingWorktree(from: window, projectID: project.id)
            case .initGit:
                break // handled above
            }
        } catch {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: branchOpErrorMessage(error),
                toHex: fromHex
            )
            return
        }

        await replyBranchOpResult(request: request, ok: true, errorMessage: nil, toHex: fromHex)
        scheduleMobileSnapshotBroadcast()
    }

    private func updateMobilePendingWorktree(from window: WindowState, projectID: UUID) {
        if let path = window.pendingWorktreePath,
           let branch = window.pendingWorktreeBranch
        {
            mobilePendingWorktrees[projectID] = MobilePendingWorktree(path: path, branch: branch)
        } else {
            mobilePendingWorktrees.removeValue(forKey: projectID)
        }
    }

    func replyBranchOpResult(
        request: BranchOpRequestPayload,
        ok: Bool,
        errorMessage: String?,
        toHex hex: String
    ) async {
        let result = BranchOpResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: request.projectID,
            operation: request.operation,
            branch: request.branch,
            ok: ok,
            errorMessage: errorMessage
        )
        await MobileSyncService.shared.send(.branchOpResult(result), toHex: hex)
    }

    func branchOpErrorMessage(_ error: Error) -> String {
        if let werr = error as? GitWorktreeService.WorktreeError {
            return werr.description
        }
        return error.localizedDescription
    }

    func handleMobileFolderTreeRequest(_ request: FolderTreeRequestPayload, fromHex: String) async {
        let result: FolderTreeResultPayload
        do {
            let root = try mobileFolderTreeRoot(for: request)
            result = FolderTreeResultPayload(
                clientRequestID: request.clientRequestID,
                requestedPath: request.path,
                ok: true,
                root: root
            )
        } catch {
            result = FolderTreeResultPayload(
                clientRequestID: request.clientRequestID,
                requestedPath: request.path,
                ok: false,
                errorMessage: mobileFolderErrorMessage(error)
            )
        }
        await MobileSyncService.shared.send(.folderTreeResult(result), toHex: fromHex)
    }

    func handleMobileCreateProjectRequest(_ request: CreateProjectRequestPayload, fromHex: String) async {
        let trimmedPath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Folder path is required.",
                toHex: fromHex
            )
            return
        }

        let url = URL(fileURLWithPath: trimmedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Folder does not exist on the desktop.",
                toHex: fromHex
            )
            return
        }

        if projects.first(where: { $0.path == url.path }) == nil {
            let isGitRepo = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
            let gitHubRepo = isGitRepo ? detectGitHubOwnerRepo(at: url.path) : nil
            await addProject(name: url.lastPathComponent, path: url.path, gitHubRepo: gitHubRepo)
        }

        guard let project = projects.first(where: { $0.path == url.path }) else {
            await replyCreateProjectResult(
                requestID: request.clientRequestID,
                ok: false,
                project: nil,
                errorMessage: "Failed to add project on the desktop.",
                toHex: fromHex
            )
            return
        }

        await replyCreateProjectResult(
            requestID: request.clientRequestID,
            ok: true,
            project: project,
            errorMessage: nil,
            toHex: fromHex
        )
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
        scheduleMobileSnapshotBroadcast()
    }

    func replyCreateProjectResult(
        requestID: UUID,
        ok: Bool,
        project: Project?,
        errorMessage: String?,
        toHex hex: String
    ) async {
        let result = CreateProjectResultPayload(
            clientRequestID: requestID,
            ok: ok,
            project: project,
            errorMessage: errorMessage
        )
        await MobileSyncService.shared.send(.createProjectResult(result), toHex: hex)
    }

    func handleMobileDeleteProjectRequest(_ request: DeleteProjectRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            // Already gone — treat as success so the phone settles to the same state.
            await replyDeleteProjectResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: true,
                errorMessage: nil,
                toHex: fromHex
            )
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        // Mobile actions aren't tied to a desktop window; a fresh WindowState
        // keeps the data-layer mutators happy without disturbing open windows.
        let window = WindowState()
        await deleteProject(project, in: window)

        await replyDeleteProjectResult(
            requestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            errorMessage: nil,
            toHex: fromHex
        )
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
        scheduleMobileSnapshotBroadcast()
    }

    func replyDeleteProjectResult(
        requestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String?,
        toHex hex: String
    ) async {
        let result = DeleteProjectResultPayload(
            clientRequestID: requestID,
            projectID: projectID,
            ok: ok,
            errorMessage: errorMessage
        )
        await MobileSyncService.shared.send(.deleteProjectResult(result), toHex: hex)
    }
}
