import Foundation
import RxCodeCore

/// Pending decisions, setup prompts, and project activity used by tab badges.
struct PendingAttention: Equatable {
    var permissions = 0
    var setups = 0
    var confirmations = 0
    var runningThreads = 0
    var unreadThreads = 0

    var count: Int { permissions + setups + confirmations + runningThreads + unreadThreads }
    var label: String {
        var parts: [String] = []
        if permissions > 0 { parts.append(String(localized: "Permissions: \(permissions)")) }
        if setups > 0 { parts.append(String(localized: "Setups: \(setups)")) }
        if confirmations > 0 { parts.append(String(localized: "Confirmations: \(confirmations)")) }
        if runningThreads > 0 { parts.append(String(localized: "Running threads: \(runningThreads)")) }
        if unreadThreads > 0 { parts.append(String(localized: "Unread threads: \(unreadThreads)")) }
        return parts.joined(separator: ", ")
    }
}

extension AppState {
    func threadAttention(sessionKey: String, in window: WindowState) -> PendingAttention {
        let resolved = resolveCurrentSessionId(sessionKey)
        return PendingAttention(
            permissions: Set(window.pendingPermissions.filter {
                $0.sessionId.map { resolveCurrentSessionId($0) == resolved } ?? false
            }.map(\.id)).count,
            confirmations: agentConfirmations(forSession: sessionKey).count
        )
    }

    /// Setup banners belong to projects, so they do not mark every child thread.
    func projectAttention(projectId: UUID, in window: WindowState) -> PendingAttention {
        var sessionIds = Set(allSessionSummaries.filter { $0.projectId == projectId }
            .map { resolveCurrentSessionId($0.id) })
        // Include a new chat before its first persisted summary is available.
        for candidate in [window] + liveWindowRefs.compactMap(\.window)
            where candidate.selectedProject?.id == projectId {
            sessionIds.insert(resolveCurrentSessionId(candidate.currentSessionId ?? candidate.newSessionKey))
        }
        return PendingAttention(
            permissions: Set(window.pendingPermissions.filter {
                $0.sessionId.map { sessionIds.contains(resolveCurrentSessionId($0)) } ?? false
            }.map(\.id)).count,
            setups: setupAttentionCount(projectId: projectId),
            confirmations: agentPrompts.confirmations.filter {
                $0.projectId == projectId || sessionIds.contains(resolveCurrentSessionId($0.sessionKey))
            }.count,
            runningThreads: sessionIds.filter { sessionActivity[$0]?.isStreaming == true }.count,
            unreadThreads: sessionIds.filter { sessionActivity[$0]?.hasUncheckedCompletion == true }.count
        )
    }

    func setupAttentionCount(projectId: UUID?) -> Int {
        // Match HookBannerHost's project and position filters exactly.
        Set((hookBanners[.newProject] ?? []).filter {
            $0.position == .aboveInputBox && ($0.projectId == nil || $0.projectId == projectId)
        }.map(\.id)).count
    }

    func windowAttention(in window: WindowState) -> PendingAttention {
        if window.isProjectWindow, let projectId = window.selectedProject?.id {
            return projectAttention(projectId: projectId, in: window)
        }
        var attention = threadAttention(sessionKey: window.currentSessionId ?? window.newSessionKey, in: window)
        attention.setups = setupAttentionCount(projectId: window.selectedProject?.id)
        return attention
    }
}
