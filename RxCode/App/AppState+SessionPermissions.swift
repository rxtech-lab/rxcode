import RxCodeCore

extension AppState {
    /// Sets the permission mode for the current session and persists it in the session state.
    /// If there's a live CLI session for this window, re-register with the PermissionServer so
    /// the new mode takes effect for the next tool call without restarting the stream.
    func setSessionPermissionMode(_ mode: PermissionMode, in window: WindowState) {
        window.sessionPermissionMode = mode
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { $0.permissionMode = mode }
        reregisterPermissionMode(in: window)
    }

    /// Toggles the boolean plan-mode flag for the active session. The CLI's permission mode
    /// is still computed from the dropdown when plan-mode is off; when on, `.plan` is forced
    /// for the CLI invocation regardless of dropdown selection (see `send(...)`).
    /// Triggered by Shift+Tab in the input bar and by the Plan pill chip.
    func toggleSessionPlanMode(in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        let next = !(sessionStates[key]?.planMode ?? window.sessionPlanMode)
        window.sessionPlanMode = next
        updateState(key) { $0.planMode = next }
        reregisterPermissionMode(in: window)
    }

    /// Tell the PermissionServer the latest effective permission mode for the live CLI session,
    /// if any. This is what makes mid-conversation mode changes (Ask → Auto, plan toggle, etc.)
    /// affect the very next tool call without restarting the stream.
    func reregisterPermissionMode(in window: WindowState) {
        guard let sid = window.currentSessionId,
              let projectPath = window.selectedProject?.path else { return }
        // Use the dropdown value (ignore plan toggle) so an explicit Auto choice
        // continues to auto-approve hook-matched tools while plan mode is on.
        // The plan toggle only affects the CLI `--permission-mode` flag, not the
        // hook auto-approve policy. ExitPlanMode is always exempt from auto-approve
        // (see PermissionServer.autoApproveReason).
        let hookSessionMode = window.sessionPermissionMode ?? permissionMode
        Task { [permission] in
            await permission.registerSession(sid: sid, projectKey: projectPath, mode: hookSessionMode)
        }
    }
}
