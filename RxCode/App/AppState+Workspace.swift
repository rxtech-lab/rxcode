import Foundation
import RxCodeCore

extension AppState {
    /// Create a new workspace in the shared registry and return it. Does not
    /// switch the current window — callers open a window for the new workspace
    /// (each workspace lives in its own window with its own `AppState`).
    @discardableResult
    func createWorkspace(named name: String) -> AppWorkspace {
        let snapshot = workspaceRegistry.createWorkspace(name: name)
        workspaces = snapshot.all
        return snapshot.active
    }

    /// Persist `id` as the registry's active workspace (restored on next launch).
    /// The window switch itself is performed by the caller via `openWindow`.
    func activateWorkspace(id: String) {
        guard let snapshot = workspaceRegistry.switchWorkspace(id: id) else { return }
        workspaces = snapshot.all
    }

    func renameWorkspace(id: String, to name: String) {
        guard let snapshot = workspaceRegistry.renameWorkspace(id: id, name: name) else { return }
        workspaces = snapshot.all
        if id == activeWorkspace.id {
            activeWorkspace = snapshot.all.first { $0.id == id } ?? activeWorkspace
        }
    }

    /// Remove a workspace from the shared registry. Closing its window and
    /// discarding its cached `AppState` is handled by the caller (the view, via
    /// `WorkspaceManager` / `dismissWindow`).
    @discardableResult
    func deleteWorkspace(id: String) -> Bool {
        guard id != AppWorkspace.personalID else { return false }
        guard let snapshot = workspaceRegistry.deleteWorkspace(id: id) else { return false }
        workspaces = snapshot.all
        return true
    }

    func loadWorkspaceSettings() {
        selectedTheme = AppTheme(rawValue: workspaceDefaults.string(for: "selectedTheme") ?? "") ?? .claude
        fontSizeAdjustment = workspaceDefaults.int(for: "fontSizeAdjustment", default: 0)
        messageFontSizeAdjustment = workspaceDefaults.int(for: "messageFontSizeAdjustment", default: 0)
        selectedModel = workspaceDefaults.string(for: "selectedModel") ?? "opus"
        selectedAgentProvider = AgentProvider(rawValue: workspaceDefaults.string(for: "selectedAgentProvider") ?? "") ?? .claudeCode
        selectedACPClientId = workspaceDefaults.string(for: "selectedACPClientId") ?? ""
        selectedEffort = workspaceDefaults.string(for: "selectedEffort") ?? "auto"

        var provider = SummarizationProvider(rawValue: workspaceDefaults.string(for: "summarizationProvider") ?? "") ?? .selectedClient
        if provider == .appleFoundationModel, !FoundationModelSummarizationService.isAvailable {
            provider = .selectedClient
        }
        summarizationProvider = provider
        openAISummarizationEndpoint = workspaceDefaults.string(for: "openAISummarizationEndpoint") ?? AppState.defaultOpenAISummarizationEndpoint
        openAISummarizationAPIKey = KeychainHelper.readString(
            service: AppState.openAISummarizationKeychainService,
            account: activeWorkspace.openAISummarizationKeychainAccount
        ) ?? ""
        openAISummarizationModel = workspaceDefaults.string(for: "openAISummarizationModel") ?? ""

        memoryEnabled = workspaceDefaults.bool(for: "memoryEnabled", default: true)
        memoryAutoCreateEnabled = workspaceDefaults.bool(for: "memoryAutoCreateEnabled", default: true)
        memoryInjectEnabled = workspaceDefaults.bool(for: "memoryInjectEnabled", default: true)
        memoryRetrievalMode = MemoryRetrievalMode(rawValue: workspaceDefaults.string(for: "memoryRetrievalMode") ?? "") ?? .balanced
        memoryMaxContextItems = workspaceDefaults.int(for: "memoryMaxContextItems", default: 5)

        notificationsEnabled = workspaceDefaults.bool(for: "notificationsEnabled", default: true)
        enableAutoCIFix = workspaceDefaults.bool(for: "enableAutoCIFix", default: false)
        focusMode = workspaceDefaults.bool(for: "focusMode", default: false)
        showRightSidebar = workspaceDefaults.bool(for: AppStorageKeys.showRightSidebar, default: false)
        rightInspectorWidth = workspaceDefaults.double(
            for: AppStorageKeys.rightInspectorWidth,
            default: RightInspectorPanelLayout.defaultWidth
        )
        autoArchiveEnabled = workspaceDefaults.bool(for: "autoArchiveEnabled", default: true)
        archiveRetentionDays = workspaceDefaults.int(for: "archiveRetentionDays", default: AppState.defaultArchiveRetentionDays)
        autoDeleteEnabled = workspaceDefaults.bool(for: "autoDeleteEnabled", default: false)
        deleteRetentionDays = workspaceDefaults.int(for: "deleteRetentionDays", default: AppState.defaultDeleteRetentionDays)

        if let data = workspaceDefaults.data(for: AppState.autoPreviewSettingsKey),
           let settings = try? JSONDecoder().decode(AttachmentAutoPreviewSettings.self, from: data)
        {
            autoPreviewSettings = settings
        } else {
            autoPreviewSettings = AttachmentAutoPreviewSettings()
        }

        permissionMode = PermissionMode(rawValue: workspaceDefaults.string(for: "selectedPermissionMode") ?? "") ?? .default
        onboardingCompleted = workspaceDefaults.bool(for: "onboardingCompleted", default: false)
        wasOnboardedAtLaunch = onboardingCompleted
        seenWhatsNewSlugs = Set(workspaceDefaults.stringArray(for: AppState.seenWhatsNewKey))
    }
}
