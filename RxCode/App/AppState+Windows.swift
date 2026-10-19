import RxCodeCore

extension AppState {
    func registerLiveWindow(_ window: WindowState) {
        window.mcpAppLoader = { [weak self, weak window] call in
            guard let self, let window else { return nil }
            return try await self.loadMCPApp(for: call, projectPath: window.selectedProject?.path)
        }
        liveWindowRefs.removeAll { $0.window == nil || $0.window === window }
        liveWindowRefs.append(WeakWindowRef(window: window))
    }

    func registeredWindows() -> [WindowState] {
        liveWindowRefs.removeAll { $0.window == nil }
        return liveWindowRefs.compactMap(\.window)
    }
}
