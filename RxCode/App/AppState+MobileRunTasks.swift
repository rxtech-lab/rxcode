import Foundation
import RxCodeCore
import RxCodeSync

// MARK: - Mobile Run Task Snapshots

extension AppState {
    func mobileRunProfiles() async -> [MobileProjectRunProfiles] {
        var result: [MobileProjectRunProfiles] = []
        for project in projects {
            await ensureRunProfilesLoaded(for: project.id)
            let profiles = runProfiles(for: project.id)
            result.append(MobileProjectRunProfiles(
                projectId: project.id,
                profiles: profiles
            ))
        }
        return result
    }

    func mobileRunTaskSnapshots() -> [MobileRunTaskSnapshot] {
        runService.tasks.map(mobileRunTaskSnapshot)
    }

    func mobileRunTaskSnapshot(_ task: RunTask) -> MobileRunTaskSnapshot {
        MobileRunTaskSnapshot(
            taskId: task.id,
            projectId: task.project.id,
            profileId: task.profile.id,
            profileName: task.profile.name,
            status: mobileRunTaskStatus(task.status),
            statusLabel: task.status.label,
            exitCode: task.exitCode,
            startedAt: task.startedAt,
            resolvedCwd: task.resolvedCwd,
            commandPreview: mobileRunTaskCommandPreview(task),
            terminalOutputTail: String(task.terminalOutputTail.suffix(8_000))
        )
    }

    func mobileRunTaskStatus(_ status: RunTaskStatus) -> MobileRunTaskSnapshot.Status {
        switch status {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .signaled: return .signaled
        case .stopped: return .stopped
        }
    }

    func mobileRunTaskCommandPreview(_ task: RunTask) -> String {
        let lines = task.wrapperScript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let mainIndex = lines.firstIndex(of: "# --- main ---") {
            return lines.dropFirst(mainIndex + 1)
                .prefix(8)
                .joined(separator: "\n")
        }
        return lines.suffix(8).joined(separator: "\n")
    }

    func broadcastMobileRunTasks() {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        let currentSnapshots = runService.tasks.prefix(5).map(mobileRunTaskSnapshot)
        let currentById = Dictionary(uniqueKeysWithValues: currentSnapshots.map { ($0.taskId, $0) })
        let removedIds = Set(lastBroadcastRunTaskSnapshots.keys).subtracting(currentById.keys)
        if !removedIds.isEmpty {
            scheduleMobileSnapshotBroadcast()
        }
        for snapshot in currentSnapshots where lastBroadcastRunTaskSnapshots[snapshot.taskId] != snapshot {
            MobileSyncService.shared.broadcastRunTaskUpdate(snapshot)
        }
        lastBroadcastRunTaskSnapshots = currentById
    }
}
