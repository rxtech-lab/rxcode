import Foundation
import RxCodeCore

extension AppState {
    func registerLiveWindow(_ window: WindowState) {
        window.pendingPermissions = mobilePendingRequests.values.sorted { $0.id < $1.id }
        window.mcpAppLoader = { [weak self, weak window] call in
            guard let self, let window else { return nil }
            return try await self.loadMCPApp(for: call, projectPath: window.selectedProject?.path,
                                             sessionKey: window.currentSessionId ?? window.newSessionKey)
        }
        liveWindowRefs.removeAll { $0.window == nil || $0.window === window }
        liveWindowRefs.append(WeakWindowRef(window: window))
    }

    func registeredWindows() -> [WindowState] {
        liveWindowRefs.removeAll { $0.window == nil }
        return liveWindowRefs.compactMap(\.window)
    }

    func registerOpenProjectWindow(_ projectId: UUID) {
        openProjectWindowCounts[projectId, default: 0] += 1
    }

    func unregisterOpenProjectWindow(_ projectId: UUID) {
        guard let count = openProjectWindowCounts[projectId] else { return }
        if count <= 1 {
            openProjectWindowCounts.removeValue(forKey: projectId)
        } else {
            openProjectWindowCounts[projectId] = count - 1
        }
    }

    func hasOpenProjectWindow(for projectId: UUID) -> Bool {
        (openProjectWindowCounts[projectId] ?? 0) > 0
    }

    /// Routes a notification tap to the right window without spawning a new one.
    /// Hands off to an existing project window if one is open for that project;
    /// otherwise navigates the supplied main window in place.
    func handleNotificationTap(projectId: UUID, sessionId: String, mainWindow: WindowState) {
        if hasOpenProjectWindow(for: projectId) {
            pendingNotificationSession[projectId] = sessionId
            return
        }
        if mainWindow.selectedProject?.id == projectId {
            guard mainWindow.currentSessionId != sessionId else { return }
            mainWindow.currentSessionId = sessionId
        } else {
            selectSession(id: sessionId, in: mainWindow)
        }
    }
}
