import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Mobile Sync — Run Profile & Runnable Detection Handlers

extension AppState {
    func handleMobileRunProfileMutation(
        _ request: RunProfileMutationRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile mutation operation=\(request.operation.rawValue, privacy: .public) project=\(request.projectID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard projects.contains(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] run profile mutation rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        await ensureRunProfilesLoaded(for: request.projectID)
        var profiles = runProfiles(for: request.projectID)
        let now = Date()

        switch request.operation {
        case .upsert:
            guard var profile = request.profile else {
                logger.error("[MobileSync] run profile upsert rejected missing payload project=\(request.projectID.uuidString, privacy: .public)")
                await replyRunProfileResult(
                    requestID: request.clientRequestID,
                    projectID: request.projectID,
                    ok: false,
                    errorMessage: "Profile payload is missing.",
                    task: nil,
                    toHex: fromHex
                )
                return
            }
            profile.projectId = request.projectID
            profile.updatedAt = now
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profile.createdAt = now
                profiles.append(profile)
            }
        case .delete:
            guard let profileID = request.profileID else {
                logger.error("[MobileSync] run profile delete rejected missing profile id project=\(request.projectID.uuidString, privacy: .public)")
                await replyRunProfileResult(
                    requestID: request.clientRequestID,
                    projectID: request.projectID,
                    ok: false,
                    errorMessage: "Profile id is missing.",
                    task: nil,
                    toHex: fromHex
                )
                return
            }
            profiles.removeAll { $0.id == profileID }
        }

        setRunProfiles(profiles, for: request.projectID)
        logger.info("[MobileSync] run profile mutation applied project=\(request.projectID.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            errorMessage: nil,
            task: nil,
            toHex: fromHex
        )
    }

    func handleMobileRunProfileRun(
        _ request: RunProfileRunRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile run project=\(request.projectID.uuidString, privacy: .public) profile=\(request.profileID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] run profile run rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        await ensureRunProfilesLoaded(for: request.projectID)
        guard let profile = runProfiles(for: request.projectID).first(where: { $0.id == request.profileID }) else {
            logger.error("[MobileSync] run profile run rejected missing profile=\(request.profileID.uuidString, privacy: .public) project=\(request.projectID.uuidString, privacy: .public) knownProfiles=\(self.runProfiles(for: request.projectID).count, privacy: .public)")
            await replyRunProfileResult(
                requestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Run profile not found on desktop.",
                task: nil,
                toHex: fromHex
            )
            return
        }

        let task = runService.start(profile: profile, project: project)
        logger.info("[MobileSync] run profile started task=\(task.id.uuidString, privacy: .public) profile=\(profile.name, privacy: .public) project=\(project.id.uuidString, privacy: .public)")
        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            errorMessage: nil,
            task: mobileRunTaskSnapshot(task),
            toHex: fromHex
        )
    }

    func handleMobileRunProfileStop(
        _ request: RunProfileStopRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling run profile stop task=\(request.taskID?.uuidString ?? "<nil>", privacy: .public) project=\(request.projectID?.uuidString ?? "<nil>", privacy: .public) profile=\(request.profileID?.uuidString ?? "<nil>", privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        let stoppedTask: RunTask?
        if let taskID = request.taskID {
            stoppedTask = runService.task(id: taskID)
            runService.stop(taskId: taskID)
        } else if let projectID = request.projectID, let profileID = request.profileID {
            stoppedTask = runService.activeTasks.first {
                $0.project.id == projectID && $0.profile.id == profileID
            }
            if let stoppedTask {
                runService.stop(taskId: stoppedTask.id)
            }
        } else {
            stoppedTask = nil
        }

        await replyRunProfileResult(
            requestID: request.clientRequestID,
            projectID: request.projectID ?? stoppedTask?.project.id ?? UUID(),
            ok: stoppedTask != nil,
            errorMessage: stoppedTask == nil ? "No matching running task was found." : nil,
            task: stoppedTask.map(mobileRunTaskSnapshot),
            toHex: fromHex
        )
    }

    func replyRunProfileResult(
        requestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String?,
        task: MobileRunTaskSnapshot?,
        toHex hex: String
    ) async {
        await ensureRunProfilesLoaded(for: projectID)
        logger.info("[MobileSync] replying run profile result ok=\(ok, privacy: .public) project=\(projectID.uuidString, privacy: .public) profiles=\(self.runProfiles(for: projectID).count, privacy: .public) task=\(task?.taskId.uuidString ?? "<nil>", privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public) error=\(errorMessage ?? "<nil>", privacy: .public)")
        let result = RunProfileResultPayload(
            clientRequestID: requestID,
            projectID: projectID,
            ok: ok,
            errorMessage: errorMessage,
            profiles: runProfiles(for: projectID),
            task: task
        )
        await MobileSyncService.shared.send(.runProfileResult(result), toHex: hex)
        if ok { scheduleMobileSnapshotBroadcast() }
    }

    /// Scan a project for runnable Xcode schemes, npm scripts, and Make targets
    /// on behalf of a paired mobile device. Detection logic lives entirely on
    /// the desktop — mobile only displays the result.
    func handleMobileRunnableDetectRequest(
        _ request: RunnableDetectRequestPayload,
        fromHex: String
    ) async {
        logger.info("[MobileSync] handling runnable detection project=\(request.projectID.uuidString, privacy: .public) mobileKey=\(String(fromHex.prefix(12)), privacy: .public)")
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] runnable detection rejected unknown project=\(request.projectID.uuidString, privacy: .public)")
            let result = RunnableDetectResultPayload(
                clientRequestID: request.clientRequestID,
                projectID: request.projectID,
                ok: false,
                errorMessage: "Project not found on desktop."
            )
            await MobileSyncService.shared.send(.runnableDetectResult(result), toHex: fromHex)
            return
        }

        let detected = await RunProfileDetector().detect(in: project.path)
        logger.info("[MobileSync] runnable detection complete project=\(request.projectID.uuidString, privacy: .public) xcode=\(detected.xcode.count, privacy: .public) npm=\(detected.npm.count, privacy: .public) make=\(detected.make.count, privacy: .public)")
        let result = RunnableDetectResultPayload(
            clientRequestID: request.clientRequestID,
            projectID: request.projectID,
            ok: true,
            detected: detected
        )
        await MobileSyncService.shared.send(.runnableDetectResult(result), toHex: fromHex)
    }
}
