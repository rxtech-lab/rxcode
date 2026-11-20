extension AppState {
    /// Sessions currently streaming, anywhere across all windows.
    /// Reads `sessionActivity` (not `sessionStates`) so the menu bar label doesn't
    /// re-render its image on every stream event.
    var inProgressSessionCount: Int {
        sessionActivity.values.reduce(0) { $0 + ($1.isStreaming ? 1 : 0) }
    }

    /// Sessions whose stream finished but the user hasn't selected since. Cleared
    /// on session select via `hasUncheckedCompletion`.
    var uncheckedFinishedSessionCount: Int {
        sessionActivity.values.reduce(0) { $0 + ($1.hasUncheckedCompletion ? 1 : 0) }
    }
}
