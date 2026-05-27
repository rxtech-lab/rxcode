import Foundation
import os
import RxAuthSwift
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Per-Session Stream State

/// Encapsulates all independent state per session.
/// Stored in the `AppState.sessionStates` dictionary keyed by session ID.
struct SessionStreamState {
    // Messages
    var messages: [ChatMessage] = []

    /// Full `Attachment` objects (including image data, text content, etc.)
    /// for the most recent user turn. `ChatMessage.attachmentPaths` is lossy —
    /// it only stores name/path/type, so we keep the originals here so
    /// `cancelStreaming` can restore them into the input bar alongside the
    /// rolled-back user text.
    var inFlightUserAttachments: [Attachment] = []

    /// True while persisted messages are being loaded from disk into this session.
    /// MessageListView keeps the ScrollView hidden while this is true to avoid the
    /// empty → populated "blink" when switching to a session that isn't already in memory.
    var isLoadingFromDisk = false

    // Streaming
    var isStreaming = false
    var isThinking = false
    var needsNewMessage = false // After receiving .user(tool result), the next block starts a new ChatMessage
    var activeStreamId: UUID?
    var streamingStartDate: Date?
    var streamTask: Task<Void, Never>?
    var hasUncheckedCompletion = false

    /// Last time any stream event (system / assistant / tool result / etc.) arrived
    /// for the active stream. Updated in `processStream` and polled by the
    /// inactivity watchdog so a CLI that goes silent without exiting (broken pipe
    /// not surfaced, MCP child wedged, etc.) gets force-cleaned instead of
    /// leaving `isStreaming`/`activeStreamId` stuck — which would block every
    /// subsequent send into the thread.
    var lastStreamEventDate: Date?

    // Text delta buffer (10-token grouped flush)
    var textDeltaBuffer = ""
    var pendingToolResults: [(toolUseId: String, content: String, isError: Bool)] = []
    var flushTask: Task<Void, Never>?

    // tool_use input streaming buffer
    var activeToolId: String? // tool_use id currently receiving input_json_delta
    var activeToolInputBuffer: String = "" // accumulator for input_json_delta

    // Per-session overrides (persisted in memory across session switches)
    var agentProvider: AgentProvider?
    var model: String?
    /// Identifies which `ACPClientSpec` to use when `agentProvider == .acp`.
    var acpClientId: String?
    var effort: String?
    var permissionMode: PermissionMode?
    /// Per-session plan-mode toggle. When true, the CLI is launched with `--permission-mode plan`
    /// regardless of the user-selected permission mode. Cleared on session switch.
    var planMode: Bool = false
    /// User decisions for `ExitPlanMode` tool calls, keyed by `toolCallId`. Sidecar
    /// to `ToolCall.result` so the decision survives CLI-backed session reloads —
    /// the CLI emits its own follow-up tool_result ("User has approved your plan…")
    /// that we cannot prevent from overwriting `ToolCall.result` when the session
    /// jsonl is parsed fresh from disk. Loaded from `ThreadStore` on session
    /// activation, written through on every decision.
    var planDecisionSummaries: [String: String] = [:]
    /// Override cwd for this session: when set, CLI runs in this Git worktree path
    /// instead of `project.path`. Persisted on `ChatSession.worktreePath`.
    var worktreePath: String?
    var worktreeBranch: String?

    // Session statistics
    var costUsd: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var durationMs: Double = 0
    var turns: Int = 0
    /// Per-message output-token totals for the in-flight turn, keyed by the assistant
    /// message id. A single turn can contain several model invocations (one per tool-result
    /// round-trip), each emitting its own `usage.output_tokens` from zero — so we track
    /// per-id maxes and sum them to get the running turn total. Reset at stream start.
    var currentTurnOutputTokensByMessage: [String: Int] = [:]
    /// Fallback counter for assistant events that arrive without an `id` (defensive —
    /// the CLI normally always populates it). Reset alongside the map.
    var currentTurnOutputTokensUnkeyed: Int = 0
    /// Sum of all per-message running totals — what the streaming indicator displays.
    var currentTurnOutputTokens: Int {
        currentTurnOutputTokensByMessage.values.reduce(0, +) + currentTurnOutputTokensUnkeyed
    }

    var lastTurnContextUsedPercentage: Double?
    var activeModelName: String?

    /// Set once the LLM title-generation task has been spawned for this session.
    /// Prevents the early (first-text-delta) trigger and the `.result` fallback
    /// from kicking off duplicate generations on the same session.
    var titleGenerationTriggered: Bool = false

    /// File-content snapshots captured the first time this session's stream
    /// sees an Edit/MultiEdit/Write tool_use for a given path. Read
    /// synchronously at capture time (content_block_stop / assistant tool_use
    /// arrival) so we read the pre-edit state before the CLI executes the
    /// tool — large files used to lose the race when the read was async and
    /// `originalContent` would end up matching `modifiedContent`. Absence of a
    /// key means the path hasn't been touched yet in this session; the value
    /// can still be `nil` when the read failed (e.g. file does not exist for
    /// a new-file Write).
    var editingFileSnapshots: [String: String?] = [:]
}

enum SummarizationProvider: String, CaseIterable, Identifiable {
    case selectedClient
    case openAI
    case appleFoundationModel

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .selectedClient: return "Thread Model"
        case .openAI: return "OpenAI-Compatible Endpoint"
        case .appleFoundationModel: return "Apple Foundation Model"
        }
    }

    var displayNameText: String {
        String(localized: displayName)
    }

    /// Returns the providers that should be offered to the user right now.
    /// Apple Foundation Model is hidden when the device doesn't support it
    /// (non-Apple-Silicon Mac, Apple Intelligence disabled, etc.).
    @MainActor
    static var availableCases: [SummarizationProvider] {
        allCases.filter { provider in
            switch provider {
            case .appleFoundationModel:
                return FoundationModelSummarizationService.isAvailable
            case .selectedClient, .openAI:
                return true
            }
        }
    }
}

@Observable
@MainActor
final class AppState {
    // MARK: - Logger

    let logger = Logger(subsystem: "com.claudework", category: "AppState")

    // MARK: - Projects (shared)

    var projects: [Project] = []

    // MARK: - Per-Session State (shared — managed independently by session ID regardless of window)

    /// Independent state for all active sessions. Key: sessionId
    /// `internal` (not private) — read access required from WindowState / extensions
    var sessionStates: [String: SessionStreamState] = [:]

    /// Maps a stale session id (a `pending-...` placeholder, or a sid that was
    /// advanced by `compact_boundary`) to the current sid it was swapped to.
    /// Lets long-running async tasks (LLM title generation) resolve the current
    /// id after the swap that happens mid-stream in `processStream`.
    var sessionIdRedirect: [String: String] = [:]

    /// Callers waiting for `pending-<streamId>` to be replaced by the CLI's
    /// real `session_id` on the first `.system` event. The cross-project MCP
    /// send (`ide__send_to_thread`) holds the JSON-RPC reply until the real
    /// id is known so the sender's agent never sees a `pending-…` thread id.
    var sessionIdRenameWaiters: [String: SessionRenameWaiter] = [:]

    // MARK: - Stream Completion Tracking (cross-project MCP)

    /// Result of a finished stream. Used by `ide__send_to_thread` to surface
    /// the assistant's reply back through the MCP tool call.
    struct StreamCompletion: Sendable {
        let sessionId: String
        let assistantText: String
        let error: String?
    }

    /// Completed streams whose owners (callers of `awaitStreamCompletion`)
    /// have not yet picked up the result. Keyed by `streamId`.
    var pendingStreamCompletions: [UUID: StreamCompletion] = [:]

    /// Active callers waiting for a stream's completion. Resumed directly by
    /// `recordStreamCompletion` so the cross-project MCP handler doesn't sit
    /// in a polling loop on MainActor (which starves the target project's
    /// `processStream` and freezes its thread until the sender is cancelled).
    var streamCompletionWaiters: [UUID: StreamCompletionWaiter] = [:]

    // MARK: - Session Summaries (shared — lightweight metadata for all projects)

    var allSessionSummaries: [ChatSession.Summary] = []

    /// Bumped each time a thread file-edit row is appended in SwiftData. The
    /// "This thread" inspector reads this so SwiftUI observation re-runs the
    /// `threadFileEdits(in:)` fetch after a new Edit/Write tool call lands.
    var threadFileEditsRevision: Int = 0

    /// Pending permission/question prompts keyed by hook id. This mirrors the
    /// per-window queues so mobile thread rows can show the same attention state.
    var mobilePendingRequests: [String: PermissionRequest] = [:]

    // MARK: - Theme

    var selectedTheme: AppTheme = .init(rawValue: UserDefaults.standard.string(forKey: "selectedTheme") ?? "") ?? .claude {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: "selectedTheme")
            ThemeStore.shared.current = selectedTheme
            themeRevision += 1
        }
    }

    /// Incrementing causes NavigationSplitView to rebuild and immediately apply theme colors
    var themeRevision: Int = 0

    // MARK: - Font Size

    var fontSizeAdjustment: Int = (UserDefaults.standard.object(forKey: "fontSizeAdjustment") as? Int) ?? 0 {
        didSet {
            UserDefaults.standard.set(fontSizeAdjustment, forKey: "fontSizeAdjustment")
            ThemeStore.shared.fontSizeAdjustment = fontSizeAdjustment
            themeRevision += 1
        }
    }

    func increaseFontSize() {
        guard fontSizeAdjustment < ThemeStore.maxFontSizeAdjustment else { return }
        fontSizeAdjustment += 1
    }

    func decreaseFontSize() {
        guard fontSizeAdjustment > ThemeStore.minFontSizeAdjustment else { return }
        fontSizeAdjustment -= 1
    }

    var messageFontSizeAdjustment: Int = (UserDefaults.standard.object(forKey: "messageFontSizeAdjustment") as? Int) ?? 0 {
        didSet {
            UserDefaults.standard.set(messageFontSizeAdjustment, forKey: "messageFontSizeAdjustment")
            ThemeStore.shared.messageFontSizeAdjustment = messageFontSizeAdjustment
            themeRevision += 1
        }
    }

    func increaseMessageFontSize() {
        guard messageFontSizeAdjustment < ThemeStore.maxFontSizeAdjustment else { return }
        messageFontSizeAdjustment += 1
    }

    func decreaseMessageFontSize() {
        guard messageFontSizeAdjustment > ThemeStore.minFontSizeAdjustment else { return }
        messageFontSizeAdjustment -= 1
    }


    var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "opus" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var selectedAgentProvider: AgentProvider = .init(rawValue: UserDefaults.standard.string(forKey: "selectedAgentProvider") ?? "") ?? .claudeCode {
        didSet { UserDefaults.standard.set(selectedAgentProvider.rawValue, forKey: "selectedAgentProvider") }
    }

    var codexModels: [AgentModel] = []

    // MARK: - ACP

    /// User-installed ACP clients. Loaded from disk on init.
    var acpClients: [ACPClientSpec] = []
    /// Cached registry from `cdn.agentclientprotocol.com`. Refreshed hourly.
    var acpRegistry: ACPRegistry?
    var acpRegistryLoading: Bool = false

    /// Selected default ACP client id (when `selectedAgentProvider == .acp`).
    var selectedACPClientId: String = UserDefaults.standard.string(forKey: "selectedACPClientId") ?? "" {
        didSet { UserDefaults.standard.set(selectedACPClientId, forKey: "selectedACPClientId") }
    }

    var selectedEffort: String = UserDefaults.standard.string(forKey: "selectedEffort") ?? "auto" {
        didSet { UserDefaults.standard.set(selectedEffort, forKey: "selectedEffort") }
    }

    // MARK: - Summarization

    var summarizationProvider: SummarizationProvider = {
        let stored = SummarizationProvider(rawValue: UserDefaults.standard.string(forKey: "summarizationProvider") ?? "") ?? .selectedClient
        if stored == .appleFoundationModel, !FoundationModelSummarizationService.isAvailable {
            return .selectedClient
        }
        return stored
    }() {
        didSet { UserDefaults.standard.set(summarizationProvider.rawValue, forKey: "summarizationProvider") }
    }

    var openAISummarizationEndpoint: String = UserDefaults.standard.string(forKey: "openAISummarizationEndpoint") ?? AppState.defaultOpenAISummarizationEndpoint {
        didSet { UserDefaults.standard.set(openAISummarizationEndpoint, forKey: "openAISummarizationEndpoint") }
    }

    var openAISummarizationAPIKey: String = KeychainHelper.readString(
        service: AppState.openAISummarizationKeychainService,
        account: AppState.openAISummarizationKeychainAccount
    ) ?? "" {
        didSet {
            let trimmed = openAISummarizationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if trimmed.isEmpty {
                    try KeychainHelper.delete(
                        service: AppState.openAISummarizationKeychainService,
                        account: AppState.openAISummarizationKeychainAccount
                    )
                } else if let data = trimmed.data(using: .utf8) {
                    try KeychainHelper.save(
                        data,
                        service: AppState.openAISummarizationKeychainService,
                        account: AppState.openAISummarizationKeychainAccount
                    )
                }
            } catch {
                logger.warning("Failed to update OpenAI summarization API key: \(error.localizedDescription)")
            }
        }
    }

    var openAISummarizationModel: String = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? "" {
        didSet { UserDefaults.standard.set(openAISummarizationModel, forKey: "openAISummarizationModel") }
    }

    var openAISummarizationModels: [String] = []
    var openAISummarizationModelsError: String?
    var isLoadingOpenAISummarizationModels = false
    var threadSummaryRevision = 0
    var branchBriefingRevision = 0

    // MARK: - Memory

    var memoryEnabled: Bool = (UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled") }
    }

    var memoryAutoCreateEnabled: Bool = (UserDefaults.standard.object(forKey: "memoryAutoCreateEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(memoryAutoCreateEnabled, forKey: "memoryAutoCreateEnabled") }
    }

    var memoryInjectEnabled: Bool = (UserDefaults.standard.object(forKey: "memoryInjectEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(memoryInjectEnabled, forKey: "memoryInjectEnabled") }
    }

    var memoryMaxContextItems: Int = (UserDefaults.standard.object(forKey: "memoryMaxContextItems") as? Int) ?? 5 {
        didSet {
            let clamped = max(1, min(12, memoryMaxContextItems))
            if clamped != memoryMaxContextItems {
                memoryMaxContextItems = clamped
                return
            }
            UserDefaults.standard.set(memoryMaxContextItems, forKey: "memoryMaxContextItems")
        }
    }

    var memoryRevision = 0
    @ObservationIgnored var memoryInjectionIntentCache: [String: Bool] = [:]

    // MARK: - Notifications

    var notificationsEnabled: Bool = (UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    // MARK: - Focus Mode

    var focusMode: Bool = (UserDefaults.standard.object(forKey: "focusMode") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(focusMode, forKey: "focusMode") }
    }

    // MARK: - Archive

    /// Auto-archive chats whose `updatedAt` is older than this many days. Pinned
    /// chats are skipped. A value <= 0 with `autoArchiveEnabled` still leaves
    /// chats alone — the toggle is authoritative.
    static let defaultArchiveRetentionDays = 7

    var autoArchiveEnabled: Bool = (UserDefaults.standard.object(forKey: "autoArchiveEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoArchiveEnabled, forKey: "autoArchiveEnabled") }
    }

    var archiveRetentionDays: Int = (UserDefaults.standard.object(forKey: "archiveRetentionDays") as? Int) ?? AppState.defaultArchiveRetentionDays {
        didSet {
            let clamped = max(1, min(365, archiveRetentionDays))
            if clamped != archiveRetentionDays {
                archiveRetentionDays = clamped
                return
            }
            UserDefaults.standard.set(archiveRetentionDays, forKey: "archiveRetentionDays")
        }
    }

    /// Auto-delete archived chats whose `archivedAt` is older than this many days.
    /// Pinned chats are never auto-deleted. Disabled by default — destructive.
    static let defaultDeleteRetentionDays = 30

    var autoDeleteEnabled: Bool = (UserDefaults.standard.object(forKey: "autoDeleteEnabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(autoDeleteEnabled, forKey: "autoDeleteEnabled") }
    }

    var deleteRetentionDays: Int = (UserDefaults.standard.object(forKey: "deleteRetentionDays") as? Int) ?? AppState.defaultDeleteRetentionDays {
        didSet {
            let clamped = max(1, min(365, deleteRetentionDays))
            if clamped != deleteRetentionDays {
                deleteRetentionDays = clamped
                return
            }
            UserDefaults.standard.set(deleteRetentionDays, forKey: "deleteRetentionDays")
        }
    }

    // MARK: - Attachment Auto-Preview Settings

    static let autoPreviewSettingsKey = "attachmentAutoPreviewSettings"

    var autoPreviewSettings: AttachmentAutoPreviewSettings = {
        guard let data = UserDefaults.standard.data(forKey: AppState.autoPreviewSettingsKey),
              let settings = try? JSONDecoder().decode(AttachmentAutoPreviewSettings.self, from: data)
        else {
            return AttachmentAutoPreviewSettings()
        }
        return settings
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(autoPreviewSettings) {
                UserDefaults.standard.set(data, forKey: AppState.autoPreviewSettingsKey)
            }
        }
    }

    /// Pending session to navigate to when a project window opens or is already open.
    /// Keyed by projectId; consumed once applied.
    var pendingNotificationSession: [UUID: String] = [:]

    // MARK: - Menu Bar Status

    /// Last-fetched usage percentages for the menu-bar status popup. Updated by
    /// `refreshRateLimitUsage()`; nil until first successful fetch (or when not
    /// signed in to Claude Code).
    var latestRateLimitUsage: RateLimitUsage?
    var latestCodexRateLimitUsage: RateLimitUsage?
    @ObservationIgnored var rateLimitUsageRefreshTasks: [AgentProvider: Task<RateLimitUsage?, Never>] = [:]

    /// Sessions currently streaming, anywhere across all windows.
    var inProgressSessionCount: Int {
        sessionStates.values.reduce(0) { $0 + ($1.isStreaming ? 1 : 0) }
    }

    /// Sessions whose stream finished but the user hasn't selected since. Cleared
    /// on session select via `hasUncheckedCompletion`.
    var uncheckedFinishedSessionCount: Int {
        sessionStates.values.reduce(0) { $0 + ($1.hasUncheckedCompletion ? 1 : 0) }
    }

    func cachedRateLimitUsage(for provider: AgentProvider) -> RateLimitUsage? {
        switch provider {
        case .claudeCode:
            return latestRateLimitUsage
        case .codex:
            return latestCodexRateLimitUsage
        case .acp:
            return nil
        }
    }

    func rateLimitUsage(for provider: AgentProvider, forceRefresh: Bool = false) async -> RateLimitUsage? {
        if !forceRefresh, let cached = cachedRateLimitUsage(for: provider) {
            return cached
        }

        if let task = rateLimitUsageRefreshTasks[provider] {
            return await task.value ?? cachedRateLimitUsage(for: provider)
        }

        let task = Task<RateLimitUsage?, Never> { [weak self] in
            guard let self else { return nil }
            switch provider {
            case .claudeCode:
                return await RateLimitService.shared.fetchUsage(forceRefresh: forceRefresh)
            case .codex:
                guard self.codexInstalled else { return nil }
                return await self.codex.fetchRateLimits(forceRefresh: forceRefresh)
            case .acp:
                return nil
            }
        }
        rateLimitUsageRefreshTasks[provider] = task

        let usage = await task.value
        rateLimitUsageRefreshTasks[provider] = nil

        if let usage {
            storeRateLimitUsage(usage, for: provider)
            return usage
        }
        return cachedRateLimitUsage(for: provider)
    }

    func storeRateLimitUsage(_ usage: RateLimitUsage, for provider: AgentProvider) {
        switch provider {
        case .claudeCode:
            latestRateLimitUsage = usage
        case .codex:
            latestCodexRateLimitUsage = usage
        case .acp:
            break
        }
        // Refresh the mobile home-screen widget's usage figures.
        MobileSyncService.shared.pushWidgetUpdate()
    }

    /// Force-refresh the shared Claude rate-limit usage.
    func refreshRateLimitUsage(forceRefresh: Bool = false) async {
        _ = await rateLimitUsage(for: .claudeCode, forceRefresh: forceRefresh)
    }

    /// Warm Codex usage early so the status bar can render Codex limits from cache.
    func refreshCodexRateLimitUsage(forceRefresh: Bool = false) async {
        _ = await rateLimitUsage(for: .codex, forceRefresh: forceRefresh)
    }

    func refreshSelectedAgentRateLimitUsage(forceRefresh: Bool = false) async {
        switch selectedAgentProvider {
        case .claudeCode:
            await refreshRateLimitUsage(forceRefresh: forceRefresh)
        case .codex:
            await refreshCodexRateLimitUsage(forceRefresh: forceRefresh)
        case .acp:
            break
        }
    }

    func setDefaultAgentProvider(_ provider: AgentProvider) {
        guard provider != selectedAgentProvider else { return }

        selectedAgentProvider = provider
        if let model = availableAgentModelSections()
            .first(where: { $0.provider == provider })?
            .models
            .first?
            .id
        {
            selectedModel = model
        }
    }

    /// Ref-counted set of projectIds with at least one open dedicated project window.
    /// Used to decide whether a notification tap should route to the main window or
    /// hand off to an existing project window via `pendingNotificationSession`.
    @ObservationIgnored
    var openProjectWindowCounts: [UUID: Int] = [:]

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

    func isModelAvailable(_ model: String, provider: AgentProvider) -> Bool {
        availableAgentModelSections()
            .flatMap(\.models)
            .contains { $0.provider == provider && $0.id == model }
    }

    func projectDefaultModelSelection(for project: Project?) -> (provider: AgentProvider, model: String)? {
        guard let project,
              let provider = project.lastAgentProvider,
              let model = project.lastModel,
              isModelAvailable(model, provider: provider)
        else {
            return nil
        }
        return (provider, model)
    }

    func defaultModelSelection(for project: Project?) -> (provider: AgentProvider, model: String) {
        projectDefaultModelSelection(for: project) ?? (selectedAgentProvider, selectedModel)
    }

    func effectiveModelSelection(in window: WindowState) -> (provider: AgentProvider, model: String) {
        if let provider = window.sessionAgentProvider, let model = window.sessionModel {
            return (provider, model)
        }
        if let model = window.sessionModel {
            return (window.sessionAgentProvider ?? selectedAgentProvider, model)
        }
        return defaultModelSelection(for: window.selectedProject)
    }

    func rememberProjectModelSelection(_ model: String, provider: AgentProvider, in window: WindowState) {
        guard let project = window.selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id })
        else {
            return
        }

        guard projects[index].lastAgentProvider != provider || projects[index].lastModel != model else {
            return
        }

        projects[index].lastAgentProvider = provider
        projects[index].lastModel = model
        window.selectedProject = projects[index]

        Task {
            do {
                try await persistence.saveProjects(projects)
            } catch {
                logger.error("Failed to save project model selection: \(error.localizedDescription)")
            }
        }
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

    /// Sets the model for the current session and persists it in the session state.
    func setSessionModel(_ model: String, provider: AgentProvider? = nil, in window: WindowState) {
        let resolvedProvider = provider ?? window.sessionAgentProvider ?? selectedAgentProvider
        window.sessionAgentProvider = resolvedProvider
        window.sessionModel = model
        let key = window.currentSessionId ?? window.newSessionKey
        let acpParts = resolvedProvider == .acp ? acpSelectionParts(for: model) : nil
        if let acpParts {
            selectedACPClientId = acpParts.clientId
        }
        rememberProjectModelSelection(model, provider: resolvedProvider, in: window)
        updateState(key) { state in
            state.agentProvider = resolvedProvider
            state.model = model
            state.acpClientId = acpParts?.clientId
            // Drop the cached CLI-reported name so the status line reflects the
            // user's choice immediately; the next system event will refill it.
            state.activeModelName = nil
        }
    }

    /// Sets only the active client for the current session. The model is resolved to the
    /// current default for that client when possible, otherwise the first available model.
    func setSessionProvider(_ provider: AgentProvider, in window: WindowState) {
        let currentProvider = window.sessionAgentProvider ?? selectedAgentProvider
        guard provider != currentProvider else { return }

        let fallbackModel = availableAgentModelSections()
            .first { $0.provider == provider }?
            .models
            .first?
            .id
        let model = selectedAgentProvider == provider ? selectedModel : (fallbackModel ?? selectedModel)
        setSessionModel(model, provider: provider, in: window)
    }

    /// Sets the effort for the current session and persists it in the session state.
    func setSessionEffort(_ effort: String?, in window: WindowState) {
        window.sessionEffort = effort
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { $0.effort = effort }
    }

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

    func modelDisplayName(for model: String, provider: AgentProvider, in window: WindowState) -> String {
        if let active = activeModelName(in: window) {
            return active
        }
        return modelDisplayLabel(model, provider: provider)
    }

    static func formatModelId(_ raw: String) -> String {
        let lower = raw.lowercased()
        let family: String
        if lower.contains("opus") { family = "Opus" }
        else if lower.contains("sonnet") { family = "Sonnet" }
        else if lower.contains("haiku") { family = "Haiku" }
        else { return raw }

        let parts = lower.components(separatedBy: CharacterSet(charactersIn: "-"))
        if let idx = parts.firstIndex(where: { $0 == family.lowercased() }),
           idx + 1 < parts.count
        {
            let ver = parts[(idx + 1)...].prefix(2).filter { $0.allSatisfy(\.isNumber) }
            if !ver.isEmpty { return "\(family) \(ver.joined(separator: "."))" }
        }
        return family
    }

    // MARK: - Permissions

    var permissionMode: PermissionMode = .default {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: "selectedPermissionMode") }
    }

    // MARK: - rxauth + autopilot

    /// Single source of truth for sign-in status. Reads through to the
    /// shared `OAuthManager`, so every UI surface (toolbar sheet, settings
    /// tab, sidebar) stays in sync regardless of which one triggered the
    /// state change. `OAuthManager` is `@Observable`, so SwiftUI tracks
    /// these reads transitively.
    var isSignedIn: Bool { rxAuth.manager.authState == .authenticated }
    var rxUser: User? { rxAuth.manager.currentUser }
    var repos: [AutopilotRepo] = []
    var isLoadingRepos = false
    /// True while a `loadMoreRepos()` call is in flight. Separate from
    /// `isLoadingRepos` so the list keeps rendering existing rows while a
    /// follow-on page is fetched and only the footer shows a spinner.
    var isLoadingMoreRepos = false
    /// Cursor returned by the server for the next page, or `nil` when the
    /// last page has been consumed.
    var repoNextCursor: String?
    /// `true` while the server reports more pages are available for the
    /// current `(search, refresh)` request.
    var repoHasMoreRepos = false
    /// Search term used for the currently loaded page set. Tracked so
    /// out-of-order responses from a stale query can be ignored.
    var repoCurrentSearch: String = ""

    /// `nil` = unknown (not yet probed), `true`/`false` = result of the last
    /// `autopilot.precheckInstallations()` call. Drives the
    /// "Install GitHub App" empty state in `AutopilotRepoSheet`.
    var hasGitHubAppInstalled: Bool?
    var isCheckingInstall = false
    var isOpeningInstallUrl = false

    /// GitHub App installations owned by the signed-in user. Used to look up
    /// owner avatars in the import-repo sheet so each row gets a recognizable
    /// glyph instead of a generic icon.
    var installations: [AutopilotInstallation] = []

    // MARK: - CLI Version

    var claudeVersion: String?
    var codexVersion: String?
    var claudeBinaryPath: String?
    var codexBinaryPath: String?

    // MARK: - Marketplace

    var marketplaceCatalog: [MarketplacePlugin] = []
    var marketplaceLoading = false
    var marketplaceInstalledNames: Set<String> = []
    var marketplacePluginStates: [String: PluginInstallStatus] = [:]
    var marketplaceCustomSources: [MarketplaceCustomSource] = []
    var marketplaceSourceError: String?

    // MARK: - Onboarding

    var claudeInstalled = false
    var codexInstalled = false
    var onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")

    // MARK: - App Initialization

    /// True once `initialize()` has finished its first run. UI shows a loading
    /// screen until this flips so we never render the main view against
    /// half-loaded projects/sessions.
    var isInitialized = false

    // MARK: - Services

    let rxAuth = RxAuthService.shared
    let autopilot: AutopilotService
    let permission = PermissionServer()
    let metaStore = SessionMetaStore()
    let cliStore: CLISessionStore
    let claude: ClaudeService
    let codex: CodexAppServer
    let acp: ACPService

    /// Test-only seam — populated by XCTests to substitute a mock backend for
    /// the production `claude` / `codex` / `acp` services. `backend(for:)`
    /// returns the override if one is registered, otherwise falls through to
    /// the real service. Production code never writes to this dictionary.
    var agentBackendOverrides: [AgentProvider: any AgentBackend] = [:]
    let acpRegistryService = ACPRegistryService()
    let openAISummarization = OpenAISummarizationService()
    let foundationModelSummarization = FoundationModelSummarizationService()
    let persistence: any AppStatePersistenceService
    let marketplace = MarketplaceService()
    let mcp: MCPService
    let threadStore: ThreadStore
    let searchService = ThreadSearchService()
    let memoryService = MemoryService()
    /// Live progress for a user-triggered full reindex. `nil` when idle.
    var reindexProgress: (done: Int, total: Int)? = nil
    let runService = RunService()
    let localWebProxy = LocalWebProxyServer()
    let ideMCPServer = IDEMCPServer()
    var mobileSyncObservers: [NSObjectProtocol] = []

    /// Weak refs to every `WindowState` that's been wired up via `setupChatBridge`.
    /// Used by AppState-driven queue maintenance (e.g. `flushNextQueuedMessageIfNeeded`)
    /// to scrub stale entries out of each window's in-memory queue mirror.
    struct WeakWindowRef { weak var window: WindowState? }
    var liveWindowRefs: [WeakWindowRef] = []

    func registerLiveWindow(_ window: WindowState) {
        liveWindowRefs.removeAll { $0.window == nil || $0.window === window }
        liveWindowRefs.append(WeakWindowRef(window: window))
    }

    func registeredWindows() -> [WindowState] {
        liveWindowRefs.removeAll { $0.window == nil }
        return liveWindowRefs.compactMap(\.window)
    }
    var mobileSnapshotBroadcastTask: Task<Void, Never>?
    var lastBroadcastRunTaskSnapshots: [UUID: MobileRunTaskSnapshot] = [:]

    /// Worktrees freshly created by a mobile "create branch" request, keyed by
    /// project. Consumed by the next mobile new-session request for the same
    /// project so the thread spawns into the new worktree.
    struct MobilePendingWorktree {
        let path: String
        let branch: String
    }
    var mobilePendingWorktrees: [UUID: MobilePendingWorktree] = [:]

    // MARK: - Run Profiles

    /// Loaded lazily per project. Keyed by `Project.id`.
    var runProfilesByProject: [UUID: [RunProfile]] = [:]

    func runProfiles(for projectId: UUID) -> [RunProfile] {
        runProfilesByProject[projectId] ?? []
    }

    /// Load this project's run profiles from disk if we haven't already.
    /// No-op if already loaded.
    func ensureRunProfilesLoaded(for projectId: UUID) async {
        if runProfilesByProject[projectId] != nil { return }
        let loaded = await persistence.loadRunProfiles(projectId: projectId)
        runProfilesByProject[projectId] = loaded
    }

    /// Replace the in-memory list and persist atomically.
    func setRunProfiles(_ profiles: [RunProfile], for projectId: UUID) {
        runProfilesByProject[projectId] = profiles
        logger.info("[MobileSync] desktop run profiles changed project=\(projectId.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
        scheduleMobileSnapshotBroadcast()
        Task { [persistence] in
            do {
                try await persistence.saveRunProfiles(profiles, projectId: projectId)
                logger.info("[MobileSync] persisted run profiles project=\(projectId.uuidString, privacy: .public) count=\(profiles.count, privacy: .public)")
            } catch {
                logger.error("Failed to save run profiles: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Disk-persisted draft queues loaded at init. Hydrated into each
    /// `WindowState.draftQueues` when the window is initialized so messages
    /// queued during a prior run reappear in their session's input bar.
    var persistedQueues: [String: [QueuedMessage]] = [:]

    // MARK: - MCP State

    var mcpServers: [MCPServerInfo] = []
    /// Keyed by `MCPServerInfo.id` (scope:projectPath:name) so rows with the same
    /// name across different scopes/projects don't collide.
    var mcpProbeResults: [String: MCPProbeResult] = [:]
    var mcpInFlightProbes: Set<String> = []
    var mcpIsLoading: Bool = false
    var mcpListError: String?
    var mcpPeriodicProbeTask: Task<Void, Never>?
    /// 5 minutes — balances disconnect-detection latency against probe cost
    /// (each tick spawns one stdio subprocess per stdio server).
    static let mcpPeriodicProbeInterval: UInt64 = 300 * 1_000_000_000

    /// Last project selected in any window — used to scope Local / Project MCP rows
    /// in the (window-less) Settings sheet.
    var activeProjectPath: String?

    init(
        persistence injectedPersistence: (any AppStatePersistenceService)? = nil,
        startBackgroundServices: Bool = true
    ) {
        let metaStore = self.metaStore
        let cliStore = CLISessionStore(metaStore: metaStore)
        self.cliStore = cliStore
        let claude = ClaudeService(cliStore: cliStore)
        self.claude = claude
        self.codex = CodexAppServer()
        let acp = ACPService()
        self.acp = acp
        self.persistence = injectedPersistence ?? PersistenceService(metaStore: metaStore, cliStore: cliStore)
        self.mcp = MCPService(claudeService: claude)
        self.threadStore = ThreadStore.make()
        self.autopilot = AutopilotService(rxAuth: RxAuthService.shared)
        self.runService.onTasksChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.broadcastMobileRunTasks()
            }
        }

        if startBackgroundServices {
            // Bridge ACP `session/request_permission` and Codex in-band permission
            // requests into the existing PermissionServer.
            let permission = self.permission
            let codex = self.codex
            let ideMCPServer = self.ideMCPServer
            Task {
                await acp.setPermissionServer(permission)
                await codex.setPermissionServer(permission)
                await ideMCPServer.setHandler(self)
            }

            // Boot the on-device thread search index in the background. The actor
            // loads cached chunks on `start`, then kicks off a one-time backfill
            // of any threads that don't have chunks yet.
            let searchService = self.searchService
            let memoryService = self.memoryService
            let threadStore = self.threadStore
            let persistence = self.persistence
            Task.detached(priority: .utility) { [weak self] in
                await searchService.start(threadStore: threadStore)
                await memoryService.start(threadStore: threadStore)
                await searchService.backfillIfNeeded(
                    loadAll: { @MainActor in threadStore.loadAllSummaries() },
                    loadFull: { @MainActor summary -> ChatSession? in
                        let cwd = self?.projects.first(where: { $0.id == summary.projectId })?.path ?? ""
                        return await persistence.loadFullSession(summary: summary, cwd: cwd)
                    }
                )
            }

            setupMobileSyncBridge()
        }
    }


    // MARK: - Relocated Stored Properties

    /// snapshot and every subsequent `load_more_messages` page reuse one parse
    /// instead of re-reading the whole jsonl each time — without holding many
    /// threads in memory. Live (streaming) sessions bypass this entirely.
    var mobileFullMessageCache: (sessionID: String, messages: [ChatMessage])?


    /// Last seen jsonl byte size per session — used as a cheap drift signal
    /// in `reconcileFromDisk` so the no-drift path skips the full mmap+parse.
    var lastReconciledJsonlSize: [String: UInt64] = [:]

    /// Monotonic counter stamped into every outgoing `SnapshotPayload.seq`.
    /// Lets mobile reject snapshots that arrive out of order — a fresher one
    /// sent right after an older one is no longer at risk of being clobbered
    /// when the older one finally lands on the relay. Starts at `1` so any
    /// non-zero value distinguishes "stamped by a sequencing-aware desktop"
    /// from the wire default (`nil`).
    @ObservationIgnored
    var mobileSnapshotSeq: UInt64 = 0

    func nextMobileSnapshotSeq() -> UInt64 {
        mobileSnapshotSeq &+= 1
        if mobileSnapshotSeq == 0 { mobileSnapshotSeq = 1 } // skip wraparound zero
        return mobileSnapshotSeq
    }
}

// MARK: - App Errors

enum AppError: LocalizedError {
    case noProjectSelected
    case claudeNotInstalled
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectSelected:
            return "No project selected. Please select or add a project first."
        case .claudeNotInstalled:
            return "Claude CLI binary not found. Please install it first."
        case .streamFailed(let message):
            return message
        }
    }
}
