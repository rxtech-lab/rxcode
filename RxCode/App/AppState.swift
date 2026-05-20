import Foundation
import os
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

    // Text delta buffer (50ms throttle)
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
}

enum SummarizationProvider: String, CaseIterable, Identifiable {
    case selectedClient
    case openAI
    case appleFoundationModel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selectedClient: return "Thread Model"
        case .openAI: return "OpenAI-Compatible Endpoint"
        case .appleFoundationModel: return "Apple Foundation Model"
        }
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

    private let logger = Logger(subsystem: "com.claudework", category: "AppState")

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
    private var sessionIdRedirect: [String: String] = [:]

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
    private var pendingStreamCompletions: [UUID: StreamCompletion] = [:]

    // MARK: - Session Summaries (shared — lightweight metadata for all projects)

    var allSessionSummaries: [ChatSession.Summary] = []

    /// Bumped each time a thread file-edit row is appended in SwiftData. The
    /// "This thread" inspector reads this so SwiftUI observation re-runs the
    /// `threadFileEdits(in:)` fetch after a new Edit/Write tool call lands.
    var threadFileEditsRevision: Int = 0

    /// Pending permission/question prompts keyed by hook id. This mirrors the
    /// per-window queues so mobile thread rows can show the same attention state.
    private var mobilePendingRequests: [String: PermissionRequest] = [:]

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

    // MARK: - Model

    static let availableModels = ["default", "best", "opus", "opus[1m]", "opusplan", "sonnet", "sonnet[1m]", "haiku"]
    static let fallbackCodexModels = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex"]
    nonisolated static let defaultOpenAISummarizationEndpoint = "https://api.openai.com/v1"
    private static let openAISummarizationKeychainService = "com.idealapp.RxCode.openai-summarization"
    private static let openAISummarizationKeychainAccount = "apiKey"

    static var availableClaudeModels: [AgentModel] {
        availableModels.map {
            AgentModel(provider: .claudeCode, id: $0, displayName: modelDisplayName($0), description: modelDescription($0))
        }
    }

    static func availableCodexModels(_ discovered: [AgentModel]) -> [AgentModel] {
        if !discovered.isEmpty { return discovered }
        return fallbackCodexModels.map {
            AgentModel(provider: .codex, id: $0, displayName: modelDisplayName($0, provider: .codex), description: modelDescription($0, provider: .codex))
        }
    }

    func availableAgentModelSections() -> [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] {
        var sections: [(id: String, title: String, provider: AgentProvider, iconURL: String?, models: [AgentModel])] = [
            ("claudeCode", AgentProvider.claudeCode.displayName, .claudeCode, nil, Self.availableClaudeModels),
            ("codex", AgentProvider.codex.displayName, .codex, nil, Self.availableCodexModels(codexModels)),
        ]

        // Each enabled ACP client becomes its own section, titled with the
        // client's display name (e.g. "gemini-cli"). Model ids are prefixed
        // with the client id so the selection round-trips back to the right client.
        // When no models were discovered, inject a synthetic "Default" entry
        // (empty model id) so the client is still selectable in the picker —
        // the agent picks its own default at session start.
        for client in acpClients where client.enabled {
            let models: [AgentModel]
            if let options = client.modelOptions, !options.isEmpty {
                models = options.map { option in
                    AgentModel(
                        provider: .acp,
                        id: "\(client.id)::\(option.value)",
                        displayName: option.name.isEmpty ? option.value : Self.stripACPProviderPrefix(option.name),
                        description: option.description ?? "ACP client \(client.displayName)"
                    )
                }
            } else if client.models.isEmpty {
                models = [AgentModel(
                    provider: .acp,
                    id: "\(client.id)::",
                    displayName: "Default",
                    description: "ACP client \(client.displayName)"
                )]
            } else {
                models = client.models.map { model in
                    AgentModel(
                        provider: .acp,
                        id: "\(client.id)::\(model)",
                        displayName: model,
                        description: "ACP client \(client.displayName)"
                    )
                }
            }
            sections.append(("acp:\(client.id)", client.displayName, .acp, client.iconURL, models))
        }
        return sections
    }

    /// Splits an ACP model key `<clientId>::<model>` into its parts.
    static func splitACPModelKey(_ key: String) -> (clientId: String, model: String)? {
        let parts = key.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func acpSelectionParts(for model: String?) -> (clientId: String, model: String)? {
        guard let model, !model.isEmpty else { return nil }
        if let parts = Self.splitACPModelKey(model) {
            return parts
        }
        if acpClients.contains(where: { $0.id == model }) {
            return (model, "")
        }
        if !selectedACPClientId.isEmpty {
            return (selectedACPClientId, model)
        }
        if let client = acpClients.first(where: { $0.enabled && ($0.modelOptions?.contains(where: { $0.value == model }) ?? false) }) {
            return (client.id, model)
        }
        if let client = acpClients.first(where: { $0.enabled && $0.models.contains(model) }) {
            return (client.id, model)
        }
        return nil
    }

    private func acpModelDisplayName(client: ACPClientSpec, model: String) -> String {
        if model.isEmpty {
            return "Default"
        }
        if let option = client.modelOptions?.first(where: { $0.value == model }),
           !option.name.isEmpty
        {
            return Self.stripACPProviderPrefix(option.name)
        }
        return model
    }

    /// Drops the leading `<provider>/` segment from an ACP model option name
    /// when the picker already shows the client name to the left. Example:
    /// `"OpenCode Zen/MiniMax M2.5 Free"` → `"MiniMax M2.5 Free"`. Names
    /// without a `/` are returned unchanged.
    static func stripACPProviderPrefix(_ name: String) -> String {
        guard let slash = name.lastIndex(of: "/") else { return name }
        let tail = name[name.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? name : String(tail)
    }

    /// Human-readable label for a model id, resolving ACP keys (`<clientId>::<model>`)
    /// to the client's display name plus the underlying model id ("Default" when empty).
    func modelDisplayLabel(_ model: String, provider: AgentProvider) -> String {
        if provider == .acp, let parts = acpSelectionParts(for: model) {
            guard let client = acpClients.first(where: { $0.id == parts.clientId }) else {
                return parts.model.isEmpty ? "ACP · Default" : "ACP · \(parts.model)"
            }
            return "\(client.displayName) · \(acpModelDisplayName(client: client, model: parts.model))"
        }
        return Self.modelDisplayName(model, provider: provider)
    }

    static func modelDisplayName(_ model: String) -> String {
        modelDisplayName(model, provider: .claudeCode)
    }

    static func modelDisplayName(_ model: String, provider: AgentProvider) -> String {
        if provider == .codex {
            return model
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { part in
                    part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
                }
                .joined(separator: " ")
        }
        switch model {
        case "default": return "Default"
        case "best": return "Best"
        case "opus": return "Opus"
        case "opus[1m]": return "Opus 1M"
        case "opusplan": return "Opus Plan"
        case "sonnet": return "Sonnet"
        case "sonnet[1m]": return "Sonnet 1M"
        case "haiku": return "Haiku"
        default: return model.capitalized
        }
    }

    static func modelDescription(_ model: String) -> String {
        modelDescription(model, provider: .claudeCode)
    }

    static func modelDescription(_ model: String, provider: AgentProvider) -> String {
        if provider == .codex {
            switch model {
            case "gpt-5.4": return "Balanced Codex model for everyday coding."
            case "gpt-5.4-mini": return "Fast Codex model for lighter coding tasks."
            case "gpt-5.3-codex": return "Codex-optimized coding model."
            default: return "Codex model served by the Codex app-server."
            }
        }
        let key: String
        switch model {
        case "default": key = "model.desc.default"
        case "best": key = "model.desc.best"
        case "opus": key = "model.desc.opus"
        case "opus[1m]": key = "model.desc.opus1m"
        case "opusplan": key = "model.desc.opusplan"
        case "sonnet": key = "model.desc.sonnet"
        case "sonnet[1m]": key = "model.desc.sonnet1m"
        case "haiku": key = "model.desc.haiku"
        default: return ""
        }
        return NSLocalizedString(key, comment: "")
    }

    static let availableEfforts = ["low", "medium", "high", "xhigh", "max"]

    static func permissionModeDescription(_ mode: PermissionMode) -> String {
        let key: String
        switch mode {
        case .default: key = "perm.desc.default"
        case .acceptEdits: key = "perm.desc.acceptEdits"
        case .plan: key = "perm.desc.plan"
        case .auto: key = "perm.desc.auto"
        case .bypassPermissions: key = "perm.desc.bypassPermissions"
        }
        return NSLocalizedString(key, comment: "")
    }

    static func effortDescription(_ effort: String) -> String {
        let key: String
        switch effort {
        case "auto": key = "effort.desc.auto"
        case "low": key = "effort.desc.low"
        case "medium": key = "effort.desc.medium"
        case "high": key = "effort.desc.high"
        case "xhigh": key = "effort.desc.xhigh"
        case "max": key = "effort.desc.max"
        default: return ""
        }
        return NSLocalizedString(key, comment: "")
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

    // MARK: - Attachment Auto-Preview Settings

    private static let autoPreviewSettingsKey = "attachmentAutoPreviewSettings"

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
    @ObservationIgnored private var rateLimitUsageRefreshTasks: [AgentProvider: Task<RateLimitUsage?, Never>] = [:]

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

    private func storeRateLimitUsage(_ usage: RateLimitUsage, for provider: AgentProvider) {
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

    private func isModelAvailable(_ model: String, provider: AgentProvider) -> Bool {
        availableAgentModelSections()
            .flatMap(\.models)
            .contains { $0.provider == provider && $0.id == model }
    }

    private func projectDefaultModelSelection(for project: Project?) -> (provider: AgentProvider, model: String)? {
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

    private func rememberProjectModelSelection(_ model: String, provider: AgentProvider, in window: WindowState) {
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
    private func reregisterPermissionMode(in window: WindowState) {
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

    // MARK: - GitHub

    var isLoggedIn = false
    var gitHubUser: GitHubUser?
    var repos: [GitHubRepo] = []
    var customRepos: [CustomRepo] = []
    var isCloningCustomRepo: String?

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

    let github = GitHubService()
    let permission = PermissionServer()
    let metaStore = SessionMetaStore()
    let cliStore: CLISessionStore
    let claude: ClaudeService
    let codex: CodexAppServer
    let acp: ACPService
    let acpRegistryService = ACPRegistryService()
    let openAISummarization = OpenAISummarizationService()
    let foundationModelSummarization = FoundationModelSummarizationService()
    let persistence: PersistenceService
    let marketplace = MarketplaceService()
    let mcp: MCPService
    let threadStore: ThreadStore
    let searchService = ThreadSearchService()
    /// Live progress for a user-triggered full reindex. `nil` when idle.
    var reindexProgress: (done: Int, total: Int)? = nil
    let runService = RunService()
    let localWebProxy = LocalWebProxyServer()
    let ideMCPServer = IDEMCPServer()
    private var mobileSyncObservers: [NSObjectProtocol] = []

    /// Weak refs to every `WindowState` that's been wired up via `setupChatBridge`.
    /// Used by AppState-driven queue maintenance (e.g. `flushNextQueuedMessageIfNeeded`)
    /// to scrub stale entries out of each window's in-memory queue mirror.
    private struct WeakWindowRef { weak var window: WindowState? }
    private var liveWindowRefs: [WeakWindowRef] = []

    private func registerLiveWindow(_ window: WindowState) {
        liveWindowRefs.removeAll { $0.window == nil || $0.window === window }
        liveWindowRefs.append(WeakWindowRef(window: window))
    }

    private func registeredWindows() -> [WindowState] {
        liveWindowRefs.removeAll { $0.window == nil }
        return liveWindowRefs.compactMap(\.window)
    }
    private var mobileSnapshotBroadcastTask: Task<Void, Never>?
    private var lastBroadcastRunTaskSnapshots: [UUID: MobileRunTaskSnapshot] = [:]

    /// Worktrees freshly created by a mobile "create branch" request, keyed by
    /// project. Consumed by the next mobile new-session request for the same
    /// project so the thread spawns into the new worktree.
    private struct MobilePendingWorktree {
        let path: String
        let branch: String
    }
    private var mobilePendingWorktrees: [UUID: MobilePendingWorktree] = [:]

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
    private var persistedQueues: [String: [QueuedMessage]] = [:]

    // MARK: - MCP State

    var mcpServers: [MCPServerInfo] = []
    /// Keyed by `MCPServerInfo.id` (scope:projectPath:name) so rows with the same
    /// name across different scopes/projects don't collide.
    var mcpProbeResults: [String: MCPProbeResult] = [:]
    var mcpInFlightProbes: Set<String> = []
    var mcpIsLoading: Bool = false
    var mcpListError: String?
    private var mcpPeriodicProbeTask: Task<Void, Never>?
    /// 5 minutes — balances disconnect-detection latency against probe cost
    /// (each tick spawns one stdio subprocess per stdio server).
    private static let mcpPeriodicProbeInterval: UInt64 = 300 * 1_000_000_000

    /// Last project selected in any window — used to scope Local / Project MCP rows
    /// in the (window-less) Settings sheet.
    var activeProjectPath: String?

    init() {
        let metaStore = self.metaStore
        let cliStore = CLISessionStore(metaStore: metaStore)
        self.cliStore = cliStore
        let claude = ClaudeService(cliStore: cliStore)
        self.claude = claude
        self.codex = CodexAppServer()
        let acp = ACPService()
        self.acp = acp
        self.persistence = PersistenceService(metaStore: metaStore, cliStore: cliStore)
        self.mcp = MCPService(claudeService: claude)
        self.threadStore = ThreadStore.make()
        self.runService.onTasksChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.broadcastMobileRunTasks()
            }
        }

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
        let threadStore = self.threadStore
        let persistence = self.persistence
        Task.detached(priority: .utility) { [weak self] in
            await searchService.start(threadStore: threadStore)
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

    private func setupMobileSyncBridge() {
        let center = NotificationCenter.default
        let snapshotObserver = center.addObserver(
            forName: .mobileSyncSnapshotRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String else { return }
            let activeSessionID = notification.userInfo?["activeSessionID"] as? String
            Task { @MainActor [weak self] in
                await self?.sendMobileSnapshot(toHex: fromHex, activeSessionID: activeSessionID)
            }
        }
        mobileSyncObservers.append(snapshotObserver)

        let settingsObserver = center.addObserver(
            forName: .mobileSyncSettingsUpdateReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let update = notification.userInfo?["payload"] as? MobileSettingsUpdatePayload
            else { return }
            Task { @MainActor [weak self] in
                self?.applyMobileSettingsUpdate(update)
                await self?.sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            }
        }
        mobileSyncObservers.append(settingsObserver)

        let userMessageObserver = center.addObserver(
            forName: .mobileSyncUserMessageReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let message = notification.userInfo?["payload"] as? UserMessagePayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileUserMessage(message, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(userMessageObserver)

        let cancelStreamObserver = center.addObserver(
            forName: .mobileSyncCancelStreamRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let cancel = notification.userInfo?["payload"] as? CancelStreamPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileCancelStream(cancel)
            }
        }
        mobileSyncObservers.append(cancelStreamObserver)

        let removeQueuedObserver = center.addObserver(
            forName: .mobileSyncRemoveQueuedRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? RemoveQueuedMessagePayload
            else { return }
            Task { @MainActor [weak self] in
                self?.handleMobileRemoveQueuedMessage(payload)
            }
        }
        mobileSyncObservers.append(removeQueuedObserver)

        let newSessionObserver = center.addObserver(
            forName: .mobileSyncNewSessionRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? NewSessionRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileNewSessionRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(newSessionObserver)

        let threadActionObserver = center.addObserver(
            forName: .mobileSyncThreadActionRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ThreadActionRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileThreadActionRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(threadActionObserver)

        let loadMoreObserver = center.addObserver(
            forName: .mobileSyncLoadMoreMessagesRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? LoadMoreMessagesRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileLoadMoreMessages(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(loadMoreObserver)

        let searchObserver = center.addObserver(
            forName: .mobileSyncSearchRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SearchRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSearchRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(searchObserver)

        let threadChangesObserver = center.addObserver(
            forName: .mobileSyncThreadChangesRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ThreadChangesRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileThreadChangesRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(threadChangesObserver)

        let branchOpObserver = center.addObserver(
            forName: .mobileSyncBranchOpRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? BranchOpRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileBranchOpRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(branchOpObserver)

        let folderTreeObserver = center.addObserver(
            forName: .mobileSyncFolderTreeRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? FolderTreeRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileFolderTreeRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(folderTreeObserver)

        let createProjectObserver = center.addObserver(
            forName: .mobileSyncCreateProjectRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? CreateProjectRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileCreateProjectRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(createProjectObserver)

        let runProfileMutationObserver = center.addObserver(
            forName: .mobileSyncRunProfileMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileMutation(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileMutationObserver)

        let runProfileRunObserver = center.addObserver(
            forName: .mobileSyncRunProfileRunRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileRunRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileRun(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileRunObserver)

        let runProfileStopObserver = center.addObserver(
            forName: .mobileSyncRunProfileStopRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? RunProfileStopRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileRunProfileStop(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(runProfileStopObserver)

        let questionAnswerObserver = center.addObserver(
            forName: .mobileSyncQuestionAnswerReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? QuestionAnswerPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileQuestionAnswer(payload)
            }
        }
        mobileSyncObservers.append(questionAnswerObserver)

        let planDecisionObserver = center.addObserver(
            forName: .mobileSyncPlanDecisionReceived,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = notification.userInfo?["payload"] as? PlanDecisionPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobilePlanDecision(payload)
            }
        }
        mobileSyncObservers.append(planDecisionObserver)

        let skillCatalogObserver = center.addObserver(
            forName: .mobileSyncSkillCatalogRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillCatalogRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillCatalogRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillCatalogObserver)

        let skillMutationObserver = center.addObserver(
            forName: .mobileSyncSkillMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillMutationObserver)

        let skillSourceMutationObserver = center.addObserver(
            forName: .mobileSyncSkillSourceMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? SkillSourceMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileSkillSourceMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(skillSourceMutationObserver)

        let acpRegistryObserver = center.addObserver(
            forName: .mobileSyncACPRegistryRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ACPRegistryRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileACPRegistryRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(acpRegistryObserver)

        let acpMutationObserver = center.addObserver(
            forName: .mobileSyncACPMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? ACPMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileACPMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(acpMutationObserver)

        let mcpConfigObserver = center.addObserver(
            forName: .mobileSyncMCPConfigRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? MCPConfigRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileMCPConfigRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(mcpConfigObserver)

        let mcpMutationObserver = center.addObserver(
            forName: .mobileSyncMCPMutationRequested,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let fromHex = notification.userInfo?["from"] as? String,
                  let request = notification.userInfo?["payload"] as? MCPMutationRequestPayload
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleMobileMCPMutationRequest(request, fromHex: fromHex)
            }
        }
        mobileSyncObservers.append(mcpMutationObserver)

        observeMobileSnapshotInputs()
    }

    private func observeMobileSnapshotInputs() {
        withObservationTracking {
            _ = selectedAgentProvider
            _ = selectedModel
            _ = selectedACPClientId
            _ = selectedEffort
            _ = permissionMode
            _ = notificationsEnabled
            _ = focusMode
            _ = autoArchiveEnabled
            _ = archiveRetentionDays
            _ = autoPreviewSettings
            _ = branchBriefingRevision
            _ = threadSummaryRevision
            _ = projects.count
            _ = allSessionSummaries.count
            _ = latestRateLimitUsage
            _ = latestCodexRateLimitUsage
            _ = runProfilesByProject.count
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleMobileSnapshotBroadcast()
                self?.observeMobileSnapshotInputs()
            }
        }
    }

    private func handleMobileNewSessionRequest(_ request: NewSessionRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            logger.error("[MobileSync] new thread requested for unknown project=\(request.projectID.uuidString, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        let initialText = request.initialText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !initialText.isEmpty else {
            let sessionID = createMobilePlaceholderSession(project: project, requestID: request.clientRequestID)
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: sessionID)
            return
        }

        let window = WindowState()
        window.selectedProject = project
        // Per-thread agent config captured in the mobile new-thread sheet. These
        // session-scoped fields win over the project/global defaults in
        // `effectiveModelSelection`, so the thread runs on exactly the chosen
        // model — and starts in plan mode when requested. Carrying the config in
        // the request also removes the `settings_update`/`newSessionRequest`
        // ordering race.
        if let provider = request.selectedAgentProvider {
            window.sessionAgentProvider = provider
        }
        if let model = request.selectedModel, !model.isEmpty {
            window.sessionModel = model
        }
        if let effort = request.selectedEffort, !effort.isEmpty, effort != "auto" {
            window.sessionEffort = effort
        }
        if let mode = request.permissionMode {
            window.sessionPermissionMode = mode
        }
        window.sessionPlanMode = request.planMode ?? false
        if let pending = mobilePendingWorktrees.removeValue(forKey: project.id) {
            window.pendingWorktreePath = pending.path
            window.pendingWorktreeBranch = pending.branch
        }
        _ = await sendPrompt(initialText, displayText: initialText, in: window)
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: window.currentSessionId)
    }

    /// Apply a mobile-initiated lifecycle action (rename / archive / unarchive /
    /// delete) to an existing thread, then push a fresh snapshot back so the
    /// requesting device reconciles immediately. The action mutators each
    /// schedule their own broadcast for the remaining paired devices.
    private func handleMobileThreadActionRequest(_ request: ThreadActionRequestPayload, fromHex: String) async {
        // The mobile may hold a session id the CLI has since advanced
        // (pending-→real swap, or a compaction boundary). Follow the redirect
        // chain so the action lands on the live thread.
        let sessionID = resolveCurrentSessionId(request.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            logger.error("[MobileSync] thread action=\(request.action.rawValue, privacy: .public) for unknown thread=\(request.sessionID, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        logger.info("[MobileSync] applying thread action=\(request.action.rawValue, privacy: .public) thread=\(sessionID, privacy: .public)")

        let session = summary.makeSession()
        // Mobile actions aren't tied to a desktop window; a fresh WindowState
        // keeps the data-layer mutators happy without disturbing open windows.
        let window = WindowState()

        switch request.action {
        case .rename:
            let title = request.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { break }
            await renameSession(session, to: title)
        case .archive:
            await archiveSession(session, in: window)
        case .unarchive:
            await unarchiveSession(session, in: window)
        case .delete:
            await deleteSession(session, in: window)
        }

        await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
    }

    private func handleMobileBranchOpRequest(_ request: BranchOpRequestPayload, fromHex: String) async {
        guard let project = projects.first(where: { $0.id == request.projectID }) else {
            await replyBranchOpResult(
                request: request,
                ok: false,
                errorMessage: "Project not found on desktop.",
                toHex: fromHex
            )
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
                try await switchToExistingBranch(trimmed, in: window)
            case .createNew:
                try await attachWorktree(branch: trimmed, in: window)
                if let path = window.pendingWorktreePath,
                   let branch = window.pendingWorktreeBranch
                {
                    mobilePendingWorktrees[project.id] = MobilePendingWorktree(path: path, branch: branch)
                }
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

    private func replyBranchOpResult(
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

    private func branchOpErrorMessage(_ error: Error) -> String {
        if let werr = error as? GitWorktreeService.WorktreeError {
            return werr.description
        }
        return error.localizedDescription
    }

    private func handleMobileFolderTreeRequest(_ request: FolderTreeRequestPayload, fromHex: String) async {
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

    private func handleMobileCreateProjectRequest(_ request: CreateProjectRequestPayload, fromHex: String) async {
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

    private func replyCreateProjectResult(
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

    private func handleMobileRunProfileMutation(
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

    private func handleMobileRunProfileRun(
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

    private func handleMobileRunProfileStop(
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

    private func replyRunProfileResult(
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

    // MARK: - Mobile: Skills / ACP / MCP remote management

    /// Error for malformed remote skill/ACP/MCP requests; its description is
    /// surfaced verbatim to the mobile client.
    private enum MobileRemoteConfigError: LocalizedError {
        case invalidRequest(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest(let detail): return detail
            }
        }
    }

    /// The marketplace catalog flattened into wire DTOs with current install
    /// state. `forceRefresh` bypasses the 5-minute marketplace cache.
    private func mobileSkillPlugins(forceRefresh: Bool = false) async -> [MobileSkillPlugin] {
        let catalog = await marketplace.fetchCatalog(forceRefresh: forceRefresh)
        let installed = await marketplace.installedPluginNames()
        return catalog.map { plugin in
            MobileSkillPlugin(
                id: plugin.id,
                name: plugin.name,
                summary: plugin.description,
                author: plugin.author,
                category: plugin.category,
                categoryLabel: plugin.categoryLabel,
                marketplace: plugin.marketplace,
                marketplaceLabel: plugin.marketplaceLabel,
                homepage: plugin.homepage,
                isInstalled: installed.contains(plugin.name)
            )
        }
    }

    private func mobileSkillSources() async -> [MobileSkillSource] {
        await marketplace.customSources().map { source in
            MobileSkillSource(id: source.id, displayName: source.displayName)
        }
    }

    private func handleMobileSkillCatalogRequest(_ request: SkillCatalogRequestPayload, fromHex: String) async {
        let plugins = await mobileSkillPlugins(forceRefresh: request.forceRefresh)
        let sources = await mobileSkillSources()
        let result = SkillCatalogResultPayload(
            clientRequestID: request.clientRequestID,
            ok: true,
            errorMessage: nil,
            plugins: plugins,
            sources: sources
        )
        await MobileSyncService.shared.send(.skillCatalogResult(result), toHex: fromHex)
    }

    private func handleMobileSkillMutationRequest(_ request: SkillMutationRequestPayload, fromHex: String) async {
        let catalog = await marketplace.fetchCatalog()
        guard let plugin = catalog.first(where: { $0.id == request.pluginID }) else {
            let result = SkillMutationResultPayload(
                clientRequestID: request.clientRequestID,
                operation: request.operation,
                pluginID: request.pluginID,
                ok: false,
                errorMessage: "Skill not found in the marketplace catalog.",
                plugins: await mobileSkillPlugins(),
                sources: await mobileSkillSources()
            )
            await MobileSyncService.shared.send(.skillMutationResult(result), toHex: fromHex)
            return
        }

        var ok = true
        var errorMessage: String?
        do {
            switch request.operation {
            case .install:
                try await marketplace.installPlugin(plugin)
                marketplaceInstalledNames.insert(plugin.name)
                marketplacePluginStates[plugin.id] = .installed
            case .uninstall:
                try await marketplace.uninstallPlugin(plugin)
                marketplaceInstalledNames.remove(plugin.name)
                marketplacePluginStates[plugin.id] = .notInstalled
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] skill mutation failed plugin=\(plugin.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok {
            let verb = request.operation == .install ? "installed" : "removed"
            await NotificationService.shared.postRemoteConfigChanged(
                title: "Skill \(verb) remotely",
                body: plugin.name
            )
        }

        let result = SkillMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            pluginID: request.pluginID,
            ok: ok,
            errorMessage: errorMessage,
            plugins: await mobileSkillPlugins(),
            sources: await mobileSkillSources()
        )
        await MobileSyncService.shared.send(.skillMutationResult(result), toHex: fromHex)
    }

    private func handleMobileSkillSourceMutationRequest(_ request: SkillSourceMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var sourceID = request.sourceID
        var bannerTitle: String?
        var bannerBody: String?

        do {
            switch request.operation {
            case .add:
                guard let gitURL = request.gitURL,
                      !gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MobileRemoteConfigError.invalidRequest("Missing Git repository URL.")
                }
                let source = try await marketplace.addCustomGitSource(url: gitURL, ref: request.ref)
                sourceID = source.id
                marketplaceCustomSources = await marketplace.customSources()
                bannerTitle = "Skill Git source added remotely"
                bannerBody = source.displayName
            case .remove:
                let currentSources = await marketplace.customSources()
                guard let sourceID = request.sourceID,
                      let source = currentSources.first(where: { $0.id == sourceID }) else {
                    throw MobileRemoteConfigError.invalidRequest("Skill Git source not found.")
                }
                try await marketplace.removeCustomGitSource(source)
                marketplaceCustomSources = await marketplace.customSources()
                bannerTitle = "Skill Git source removed remotely"
                bannerBody = source.displayName
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] skill source mutation failed operation=\(request.operation.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let plugins = await mobileSkillPlugins(forceRefresh: true)
        let sources = await mobileSkillSources()
        marketplaceCatalog = await marketplace.fetchCatalog()
        marketplaceInstalledNames = await marketplace.installedPluginNames()

        if ok, let bannerTitle, let bannerBody {
            await NotificationService.shared.postRemoteConfigChanged(title: bannerTitle, body: bannerBody)
        }

        let result = SkillSourceMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            sourceID: sourceID,
            ok: ok,
            errorMessage: errorMessage,
            plugins: plugins,
            sources: sources
        )
        await MobileSyncService.shared.send(.skillSourceMutationResult(result), toHex: fromHex)
    }

    private func mobileACPRegistryAgents() -> [MobileACPRegistryAgent] {
        let installedRegistryIDs = Set(acpClients.compactMap(\.registryId))
        return (acpRegistry?.agents ?? []).map { agent in
            MobileACPRegistryAgent(
                id: agent.id,
                name: agent.name,
                version: agent.version,
                summary: agent.description,
                authors: agent.authors ?? [],
                license: agent.license,
                website: agent.website,
                iconURL: agent.icon,
                isInstalled: installedRegistryIDs.contains(agent.id),
                hasBinary: agent.distribution.binary?[ACPPlatform.current] != nil,
                hasNpx: agent.distribution.npx != nil,
                hasUvx: agent.distribution.uvx != nil
            )
        }
    }

    private func mobileACPClients() -> [MobileACPClient] {
        acpClients.map { spec in
            MobileACPClient(
                id: spec.id,
                registryId: spec.registryId,
                displayName: spec.displayName,
                enabled: spec.enabled,
                launchKind: spec.launch.displayKind,
                modelCount: spec.models.count,
                iconURL: spec.iconURL
            )
        }
    }

    private func handleMobileACPRegistryRequest(_ request: ACPRegistryRequestPayload, fromHex: String) async {
        await refreshACPRegistry(forceRefresh: request.forceRefresh)
        let ok = acpRegistry != nil
        let result = ACPRegistryResultPayload(
            clientRequestID: request.clientRequestID,
            ok: ok,
            errorMessage: ok ? nil : "Could not load the ACP agent registry.",
            registryAgents: mobileACPRegistryAgents(),
            installedClients: mobileACPClients()
        )
        await MobileSyncService.shared.send(.acpRegistryResult(result), toHex: fromHex)
    }

    private func handleMobileACPMutationRequest(_ request: ACPMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var bannerTitle: String?
        var bannerBody: String?
        do {
            switch request.operation {
            case .install:
                guard let agentID = request.registryAgentID else {
                    throw MobileRemoteConfigError.invalidRequest("Missing registry agent id.")
                }
                if acpRegistry == nil { await refreshACPRegistry() }
                guard let agent = acpRegistry?.agents.first(where: { $0.id == agentID }) else {
                    throw MobileRemoteConfigError.invalidRequest("Agent not found in the registry.")
                }
                let spec = try await installACPClient(from: agent)
                addACPClient(spec)
                bannerTitle = "ACP agent installed remotely"
                bannerBody = agent.name
            case .uninstall:
                guard let clientID = request.clientID,
                      let client = acpClients.first(where: { $0.id == clientID })
                else {
                    throw MobileRemoteConfigError.invalidRequest("Installed client not found.")
                }
                removeACPClient(id: clientID)
                bannerTitle = "ACP agent removed remotely"
                bannerBody = client.displayName
            case .setEnabled:
                guard let clientID = request.clientID,
                      let enabled = request.enabled,
                      var client = acpClients.first(where: { $0.id == clientID })
                else {
                    throw MobileRemoteConfigError.invalidRequest("Installed client not found.")
                }
                client.enabled = enabled
                updateACPClient(client)
                bannerTitle = "ACP agent \(enabled ? "enabled" : "disabled") remotely"
                bannerBody = client.displayName
            }
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] acp mutation failed operation=\(request.operation.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok, let bannerTitle, let bannerBody {
            await NotificationService.shared.postRemoteConfigChanged(title: bannerTitle, body: bannerBody)
        }

        let result = ACPMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            ok: ok,
            errorMessage: errorMessage,
            registryAgents: mobileACPRegistryAgents(),
            installedClients: mobileACPClients()
        )
        await MobileSyncService.shared.send(.acpMutationResult(result), toHex: fromHex)
    }

    private func mobileMCPServer(_ record: MCPServerRecord) -> MobileMCPServer {
        let env = record.env
            .sorted { $0.key < $1.key }
            .map { MobileMCPKeyValue(key: $0.key, value: $0.value) }
        let headers = record.headers
            .sorted { $0.key < $1.key }
            .map { MobileMCPKeyValue(key: $0.key, value: $0.value) }
        let endpoint: String
        if record.transport == .stdio {
            endpoint = ([record.command ?? ""] + record.args)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            endpoint = record.url ?? ""
        }
        return MobileMCPServer(
            name: record.name,
            transport: record.transport.rawValue,
            url: record.url,
            command: record.command,
            args: record.args,
            env: env,
            headers: headers,
            isGloballyEnabled: record.isGloballyEnabled,
            endpoint: endpoint
        )
    }

    private func mobileMCPServers() async throws -> [MobileMCPServer] {
        try await mcp.globalRecords().map { mobileMCPServer($0) }
    }

    private func mcpServerSpec(from server: MobileMCPServer) -> MCPServerSpec {
        MCPServerSpec(
            name: server.name,
            transport: MCPTransport(rawValue: server.transport) ?? .stdio,
            url: server.url ?? "",
            headers: server.headers.map { MCPKeyValue(key: $0.key, value: $0.value) },
            command: server.command ?? "",
            args: server.args,
            env: server.env.map { MCPKeyValue(key: $0.key, value: $0.value) }
        )
    }

    private func handleMobileMCPConfigRequest(_ request: MCPConfigRequestPayload, fromHex: String) async {
        do {
            let servers = try await mobileMCPServers()
            let result = MCPConfigResultPayload(
                clientRequestID: request.clientRequestID,
                ok: true,
                errorMessage: nil,
                servers: servers
            )
            await MobileSyncService.shared.send(.mcpConfigResult(result), toHex: fromHex)
        } catch {
            let result = MCPConfigResultPayload(
                clientRequestID: request.clientRequestID,
                ok: false,
                errorMessage: error.localizedDescription,
                servers: []
            )
            await MobileSyncService.shared.send(.mcpConfigResult(result), toHex: fromHex)
        }
    }

    private func handleMobileMCPMutationRequest(_ request: MCPMutationRequestPayload, fromHex: String) async {
        var ok = true
        var errorMessage: String?
        var bannerTitle: String?
        do {
            switch request.operation {
            case .add:
                guard let server = request.server else {
                    throw MobileRemoteConfigError.invalidRequest("Missing server definition.")
                }
                try await mcp.add(spec: mcpServerSpec(from: server), scope: .user, projectPath: nil)
                bannerTitle = "MCP server saved remotely"
            case .remove:
                try await mcp.remove(name: request.serverName, scope: .user)
                bannerTitle = "MCP server removed remotely"
            case .setEnabled:
                guard let enabled = request.enabled else {
                    throw MobileRemoteConfigError.invalidRequest("Missing enabled flag.")
                }
                try await mcp.setGlobalEnabled(name: request.serverName, enabled: enabled)
                bannerTitle = "MCP server \(enabled ? "enabled" : "disabled") remotely"
            }
            await refreshMCPServers()
        } catch {
            ok = false
            errorMessage = error.localizedDescription
            logger.error("[MobileSync] mcp mutation failed server=\(request.serverName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if ok, let bannerTitle {
            await NotificationService.shared.postRemoteConfigChanged(title: bannerTitle, body: request.serverName)
        }

        var servers: [MobileMCPServer] = []
        do {
            servers = try await mobileMCPServers()
        } catch {
            logger.error("[MobileSync] failed reading mcp servers for reply: \(error.localizedDescription, privacy: .public)")
        }
        let result = MCPMutationResultPayload(
            clientRequestID: request.clientRequestID,
            operation: request.operation,
            serverName: request.serverName,
            ok: ok,
            errorMessage: errorMessage,
            servers: servers
        )
        await MobileSyncService.shared.send(.mcpMutationResult(result), toHex: fromHex)
    }

    private func mobileFolderTreeRoot(for request: FolderTreeRequestPayload) throws -> RemoteFolderNode {
        let depth = max(0, min(request.depth, 2))
        guard let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return RemoteFolderNode(
                name: Host.current().localizedName ?? "Mac",
                path: "",
                isSelectable: false,
                children: mobileFolderPickerRoots(depth: 1, includeHidden: request.includeHidden)
            )
        }

        return try mobileFolderNode(
            for: URL(fileURLWithPath: path).standardizedFileURL,
            depth: depth,
            includeHidden: request.includeHidden
        )
    }

    private func mobileFolderPickerRoots(depth: Int, includeHidden: Bool) -> [RemoteFolderNode] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = [
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true)
        ]

        let projectParents = projects
            .map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL }
        candidates.append(contentsOf: projectParents)

        var seen: Set<String> = []
        return candidates.compactMap { url in
            let path = url.path
            guard seen.insert(path).inserted else { return nil }
            return try? mobileFolderNode(for: url, depth: depth, includeHidden: includeHidden)
        }
    }

    private func mobileFolderNode(
        for url: URL,
        depth: Int,
        includeHidden: Bool
    ) throws -> RemoteFolderNode {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MobileFolderPickerError.notFolder
        }

        let name = url == fm.homeDirectoryForCurrentUser.standardizedFileURL
            ? "Home"
            : url.lastPathComponent
        guard depth > 0 else {
            return RemoteFolderNode(name: name, path: url.path, children: [])
        }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: options
        )) ?? []

        let children = contents
            .filter { child in
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
                      values.isDirectory == true
                else { return false }
                if !includeHidden && (values.isHidden == true || child.lastPathComponent.hasPrefix(".")) {
                    return false
                }
                return !Self.mobileFolderIgnoredNames.contains(child.lastPathComponent)
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(Self.mobileFolderMaxChildren)
            .compactMap { child in
                try? mobileFolderNode(
                    for: child.standardizedFileURL,
                    depth: depth - 1,
                    includeHidden: includeHidden
                )
            }

        return RemoteFolderNode(name: name, path: url.path, children: Array(children))
    }

    private func mobileFolderErrorMessage(_ error: Error) -> String {
        if let folderError = error as? MobileFolderPickerError {
            return folderError.localizedDescription
        }
        return error.localizedDescription
    }

    private static let mobileFolderMaxChildren = 250
    private static let mobileFolderIgnoredNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData",
        "node_modules", ".DS_Store", "Pods", "xcuserdata"
    ]

    private enum MobileFolderPickerError: LocalizedError {
        case notFolder

        var errorDescription: String? {
            switch self {
            case .notFolder:
                return "Folder does not exist on the desktop."
            }
        }
    }

    private func handleMobileCancelStream(_ cancel: CancelStreamPayload) async {
        // The mobile may hold a session id the CLI has since advanced
        // (pending-→real swap, or a compaction boundary). Follow the redirect
        // chain so the cancel lands on the live, streaming thread — otherwise
        // `sessionStates[sessionID]` is nil and the stop button is a no-op.
        let sessionID = resolveCurrentSessionId(cancel.sessionID)
        guard sessionStates[sessionID]?.isStreaming == true else {
            logger.info("[MobileSync] cancel ignored — thread=\(sessionID, privacy: .public) (from \(cancel.sessionID, privacy: .public)) is not streaming")
            return
        }
        let window = WindowState()
        window.currentSessionId = sessionID
        // Resolve the project so cancelStreaming can persist the partial
        // messages accumulated up to the cancellation point.
        if let summary = allSessionSummaries.first(where: { $0.id == sessionID }) {
            window.selectedProject = projects.first(where: { $0.id == summary.projectId })
        }
        await cancelStreaming(in: window)
        // cancelStreaming intentionally skips finalizeStreamSession, so no
        // status update is emitted — broadcast it so the mobile flips its
        // stop button back to send.
        broadcastMobileSessionStatus(sessionID: sessionID)
    }

    private func handleMobileUserMessage(_ message: UserMessagePayload, fromHex: String) async {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let sessionID = resolveCurrentSessionId(message.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else {
            logger.error("[MobileSync] user message for unknown thread=\(message.sessionID, privacy: .public)")
            await sendMobileSnapshot(toHex: fromHex, activeSessionID: nil)
            return
        }

        await hydrateMobileSessionIfNeeded(summary: summary, project: project)
        updateMobilePlaceholderTitleIfNeeded(sessionID: sessionID, firstUserMessage: text)

        // If a turn is already streaming, the mobile message goes into the
        // shared (threadStore-backed) queue so it flushes once the current turn
        // ends — same behavior as the macOS InputBarView's enqueue path.
        if sessionStates[sessionID]?.isStreaming == true {
            let queued = QueuedMessage(text: text, attachments: [])
            threadStore.appendQueued(sessionKey: sessionID, message: queued)
            appendToWindowQueueMirrors(sessionID: sessionID, message: queued)
            broadcastMobileSessionStatus(sessionID: sessionID)
            return
        }

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionID
        if sessionID.hasPrefix("pending-mobile-") {
            window.insertPendingPlaceholder(sessionID)
        }
        _ = await sendPrompt(text, displayText: text, in: window)
        await sendMobileSnapshot(toHex: fromHex, activeSessionID: window.currentSessionId)
    }

    private func handleMobileRemoveQueuedMessage(_ payload: RemoveQueuedMessagePayload) {
        threadStore.removeQueued(id: payload.queuedMessageID)
        evictFromWindowQueueMirrors(sessionID: payload.sessionID, queuedID: payload.queuedMessageID)
        broadcastMobileSessionStatus(sessionID: payload.sessionID)
    }

    /// Flushes the next queued message from threadStore as a new user turn.
    /// AppState is the single auto-flush authority — both macOS-side and
    /// mobile-side queued items are flushed here, so the two flows never
    /// race on duplicate sends. Triggered at the tail of `finalizeStreamSession`.
    ///
    /// Any macOS window currently viewing the session keeps a mirror copy of
    /// the queue in `window.messageQueue`; clear the popped entry from those
    /// mirrors so the UI doesn't show a stale queued row.
    private func flushNextQueuedMessageIfNeeded(sessionID: String) async {
        let queue = threadStore.loadQueue(sessionKey: sessionID)
        guard let next = queue.first else { return }
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else { return }

        threadStore.removeQueued(id: next.id)
        evictFromWindowQueueMirrors(sessionID: sessionID, queuedID: next.id)
        broadcastMobileSessionStatus(sessionID: sessionID)

        let window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionID
        _ = await sendPrompt(
            next.text,
            displayText: next.text,
            attachments: next.attachments,
            in: window
        )
    }

    /// Mirror of `enqueueMessage` for queue items appended by AppState itself
    /// (e.g. when a mobile-sent message arrives while the session is streaming).
    /// Every desktop window currently viewing the session keeps an in-memory
    /// copy in `messageQueue` and `draftQueues[sessionID]`; push the new entry
    /// into those mirrors so the chat UI shows the queued row immediately,
    /// matching the macOS enqueue path.
    private func appendToWindowQueueMirrors(sessionID: String, message: QueuedMessage) {
        for window in registeredWindows() where window.currentSessionId == sessionID {
            if !window.messageQueue.contains(where: { $0.id == message.id }) {
                window.messageQueue.append(message)
            }
            var mirror = window.draftQueues[sessionID] ?? []
            if !mirror.contains(where: { $0.id == message.id }) {
                mirror.append(message)
            }
            window.draftQueues[sessionID] = mirror
        }
    }

    /// macOS windows hold an in-memory mirror of the queue in `messageQueue` and
    /// in `draftQueues[sessionID]`. When AppState pops an entry from threadStore
    /// (auto-flush or remote remove), drop it from every registered window so
    /// the UI doesn't show a phantom queued row.
    private func evictFromWindowQueueMirrors(sessionID: String, queuedID: UUID) {
        for window in registeredWindows() where window.currentSessionId == sessionID {
            window.messageQueue.removeAll { $0.id == queuedID }
            if var mirror = window.draftQueues[sessionID] {
                mirror.removeAll { $0.id == queuedID }
                if mirror.isEmpty {
                    window.draftQueues.removeValue(forKey: sessionID)
                } else {
                    window.draftQueues[sessionID] = mirror
                }
            }
        }
    }

    private func createMobilePlaceholderSession(project: Project, requestID: UUID) -> String {
        let sessionID = "pending-mobile-\(requestID.uuidString)"
        if allSessionSummaries.contains(where: { $0.id == sessionID }) {
            return sessionID
        }

        let selection = defaultModelSelection(for: project)
        let session = ChatSession(
            id: sessionID,
            projectId: project.id,
            title: ChatSession.defaultTitle,
            agentProvider: selection.provider,
            model: selection.model,
            origin: selection.provider.defaultSessionOrigin
        )
        allSessionSummaries.insert(session.summary, at: 0)
        threadStore.upsert(session.summary)
        updateState(sessionID) { state in
            state.agentProvider = selection.provider
            state.model = selection.model
        }
        return sessionID
    }

    private func hydrateMobileSessionIfNeeded(summary: ChatSession.Summary, project: Project) async {
        if sessionStates[summary.id] == nil,
           let full = await persistence.loadFullSession(summary: summary, cwd: project.path) {
            updateState(summary.id) { state in
                state.messages = full.messages
            }
        }

        updateState(summary.id) { state in
            if state.agentProvider == nil { state.agentProvider = summary.agentProvider }
            if state.model == nil { state.model = summary.model }
            if state.effort == nil { state.effort = summary.effort }
            if state.permissionMode == nil { state.permissionMode = summary.permissionMode }
            if state.worktreePath == nil { state.worktreePath = summary.worktreePath }
            if state.worktreeBranch == nil { state.worktreeBranch = summary.worktreeBranch }
        }
    }

    private func updateMobilePlaceholderTitleIfNeeded(sessionID: String, firstUserMessage: String) {
        guard let index = allSessionSummaries.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = allSessionSummaries[index]
        guard current.title == ChatSession.defaultTitle || current.title.isEmpty else { return }
        allSessionSummaries[index].title = ChatSession.placeholderTitle(from: firstUserMessage)
        allSessionSummaries[index].updatedAt = Date()
        threadStore.upsert(allSessionSummaries[index])
    }

    private func scheduleMobileSnapshotBroadcast() {
        mobileSnapshotBroadcastTask?.cancel()
        mobileSnapshotBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.broadcastMobileSnapshots()
        }
    }

    private func broadcastMobileSnapshots() async {
        for device in MobileSyncService.shared.pairedDevices {
            await sendMobileSnapshot(toHex: device.pubkeyHex, activeSessionID: nil)
        }
    }

    private func handleMobileSearchRequest(_ request: SearchRequestPayload, fromHex hex: String) async {
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let empty = SearchResultsPayload(
                clientRequestID: request.clientRequestID,
                query: request.query,
                projectIDs: [],
                threadHits: []
            )
            await MobileSyncService.shared.send(.searchResults(empty), toHex: hex)
            return
        }

        let knownProjectIDs = Set(projects.map(\.id))
        let summaries = allSessionSummaries.filter { knownProjectIDs.contains($0.projectId) }
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        let semantic = await searchService.search(trimmed, limit: max(request.limit, 1))

        var threadHitByID: [String: SearchHit] = [:]
        for group in semantic {
            for hit in group.hits {
                guard let summary = summaryByID[hit.threadId] else { continue }
                let title = ChatSession.stripAttachmentMarkers(from: summary.title)
                threadHitByID[hit.threadId] = SearchHit(
                    sessionID: hit.threadId,
                    projectID: hit.projectId,
                    title: title.isEmpty ? ChatSession.defaultTitle : title,
                    snippet: hit.snippet,
                    updatedAt: summary.updatedAt,
                    score: hit.score
                )
            }
        }

        let lowered = trimmed.lowercased()
        for summary in summaries where threadHitByID[summary.id] == nil {
            let cleaned = ChatSession.stripAttachmentMarkers(from: summary.title)
            guard cleaned.lowercased().contains(lowered) else { continue }
            let title = cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
            threadHitByID[summary.id] = SearchHit(
                sessionID: summary.id,
                projectID: summary.projectId,
                title: title,
                snippet: title,
                updatedAt: summary.updatedAt,
                score: 0
            )
        }

        let threadHits = threadHitByID.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(max(request.limit, 1))

        let projectIDs = projects
            .filter { project in
                project.name.lowercased().contains(lowered)
                    || project.path.lowercased().contains(lowered)
            }
            .map(\.id)

        let payload = SearchResultsPayload(
            clientRequestID: request.clientRequestID,
            query: request.query,
            projectIDs: projectIDs,
            threadHits: Array(threadHits)
        )
        await MobileSyncService.shared.send(.searchResults(payload), toHex: hex)
    }

    private func sendMobileSnapshot(toHex hex: String, activeSessionID: String?) async {
        // Populate the OpenAI summarization model list so mobile's model
        // picker has options. Fetched at most once — a prior failure (no API
        // key, bad endpoint) is recorded in `openAISummarizationModelsError`
        // and not retried on every snapshot.
        if summarizationProvider == .openAI,
           openAISummarizationModels.isEmpty,
           openAISummarizationModelsError == nil,
           !isLoadingOpenAISummarizationModels {
            await refreshOpenAISummarizationModels()
        }
        let active = await mobileActiveSessionPayload(for: activeSessionID)
        // Viewing a thread on any paired device counts as reading it: drop the
        // "finished, unread" flag so the green indicator clears on desktop and
        // mobile alike. Done before the snapshot is built so the payload below
        // already reflects the cleared state.
        if let activeID = active.id, sessionStates[activeID]?.hasUncheckedCompletion == true {
            updateState(activeID) { $0.hasUncheckedCompletion = false }
        }
        let branches = await mobileProjectBranches()
        // Keep mobile usage reasonably fresh. Non-forced — RateLimitService's
        // 5-minute cache turns this into a no-op when usage was fetched
        // recently, so frequent snapshots don't translate into API calls. A
        // genuine refresh updates `latestRateLimitUsage`, which
        // `observeMobileSnapshotInputs` tracks, re-broadcasting the snapshot.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }
        let hostMetrics = await SystemMetricsService.shared.sample()
        let runProfiles = await mobileRunProfiles()
        let runTasks = mobileRunTaskSnapshots()
        let webProxy = await localWebProxy.proxyInfo()
        if let webProxy {
            logger.info("[WebBrowserSync] snapshot includes web proxy host=\(webProxy.host, privacy: .public) port=\(webProxy.port, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        } else {
            logger.warning("[WebBrowserSync] snapshot has no web proxy info to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        }
        let payload = SnapshotPayload(
            projects: projects,
            sessions: mobileSessionSummaries(),
            branchBriefings: mobileBranchBriefings(),
            threadSummaries: mobileThreadSummaries(),
            settings: mobileSettingsSnapshot(),
            activeSessionID: active.id,
            activeSessionMessages: active.messages,
            activeSessionHasMore: active.hasMore,
            projectBranches: branches,
            usage: MobileUsageSnapshot(
                claudeCode: latestRateLimitUsage,
                codex: latestCodexRateLimitUsage
            ),
            hostMetrics: hostMetrics,
            runProfiles: runProfiles,
            runTasks: runTasks,
            webProxy: webProxy
        )
        await MobileSyncService.shared.send(.snapshot(payload), toHex: hex)
        // The snapshot doesn't carry the question queue; send it alongside so a
        // freshly connected device renders any outstanding question banner.
        await MobileSyncService.shared.send(
            .questionQueue(QuestionQueuePayload(questions: mobilePendingQuestionPayloads())),
            toHex: hex
        )
        logger.info(
            "[MobileSync] sent snapshot projects=\(self.projects.count, privacy: .public) sessions=\(payload.sessions.count, privacy: .public) runProfileProjects=\(runProfiles.count, privacy: .public) runProfileTotal=\(runProfiles.reduce(0) { $0 + $1.profiles.count }, privacy: .public) runTasks=\(runTasks.count, privacy: .public) active=\(active.id ?? "<nil>", privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)"
        )
    }

    private func mobileSessionSummaries() -> [RxCodeSync.SessionSummary] {
        let knownProjectIds = Set(projects.map(\.id))
        return allSessionSummaries
            .filter { knownProjectIds.contains($0.projectId) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map {
                mobileSessionSummary(from: $0)
            }
    }

    private func mobileRunProfiles() async -> [MobileProjectRunProfiles] {
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

    private func mobileRunTaskSnapshots() -> [MobileRunTaskSnapshot] {
        runService.tasks.map(mobileRunTaskSnapshot)
    }

    private func mobileRunTaskSnapshot(_ task: RunTask) -> MobileRunTaskSnapshot {
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

    private func mobileRunTaskStatus(_ status: RunTaskStatus) -> MobileRunTaskSnapshot.Status {
        switch status {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .signaled: return .signaled
        case .stopped: return .stopped
        }
    }

    private func mobileRunTaskCommandPreview(_ task: RunTask) -> String {
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

    private func broadcastMobileRunTasks() {
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

    private func mobileSessionSummary(for sessionID: String) -> RxCodeSync.SessionSummary? {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return mobileSessionSummary(from: summary)
    }

    private func mobileSessionSummary(from summary: ChatSession.Summary) -> RxCodeSync.SessionSummary {
        let todos = mobileTodoItems(forSessionId: summary.id)
        let progress = mobileProgressSnapshot(forSessionId: summary.id)
        let queued = threadStore.loadQueue(sessionKey: summary.id).map {
            QueuedUserMessage(id: $0.id, text: $0.text)
        }
        return RxCodeSync.SessionSummary(
            id: summary.id,
            projectId: summary.projectId,
            title: summary.title,
            updatedAt: summary.updatedAt,
            isPinned: summary.isPinned,
            isArchived: summary.isArchived,
            isStreaming: sessionStates[summary.id]?.isStreaming ?? false,
            attention: mobileAttentionKind(forSessionId: summary.id),
            progress: progress,
            todos: todos,
            queuedMessages: queued,
            hasUncheckedCompletion: sessionStates[summary.id]?.hasUncheckedCompletion ?? false
        )
    }

    private func mobileProgressSnapshot(forSessionId id: String) -> SessionProgressSnapshot? {
        if let todos = mobileTodoItems(forSessionId: id) {
            return SessionProgressSnapshot(
                done: todos.filter { $0.status == .completed }.count,
                total: todos.count,
                inProgress: todos.contains { $0.status == .inProgress }
            )
        }

        return nil
    }

    private func mobileTodoItems(forSessionId id: String) -> [TodoItem]? {
        if let messages = sessionStates[id]?.messages,
           let todos = TodoExtractor.latest(in: messages)
        {
            return todos
        }

        guard let snapshot = threadStore.fetchTodoSnapshot(sessionId: id), snapshot.total > 0 else {
            return nil
        }

        return snapshot.items
    }

    private func mobileAttentionKind(forSessionId id: String) -> SessionAttentionKind? {
        let requests = mobilePendingRequests.values.filter { $0.sessionId == id }
        if requests.contains(where: { $0.toolName == "AskUserQuestion" }) {
            return .question
        }
        if !requests.isEmpty {
            return .permission
        }
        return nil
    }

    /// Diff two message arrays for a session and emit `messageAppended` /
    /// `messageUpdated` payloads for each change. Called from `updateState`
    /// and `flushPendingUpdates` so every visible mutation reaches mobile
    /// without per-call site instrumentation.
    private func broadcastMobileMessageDiff(
        sessionKey: String,
        prev: [ChatMessage],
        next: [ChatMessage],
        isStreaming: Bool
    ) {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        if prev.count == next.count, prev == next { return }
        // Diff against the raw messages (so a CLI result overwrite still counts
        // as a change), but bake the user-decision summary into the broadcast
        // copy so the mobile plan banner clears once a plan is resolved.
        let summaries = sessionStates[sessionKey]?.planDecisionSummaries ?? [:]
        let prevById = Dictionary(uniqueKeysWithValues: prev.map { ($0.id, $0) })
        for message in next {
            if let old = prevById[message.id] {
                guard old != message else { continue }
                MobileSyncService.shared.broadcastSessionUpdate(
                    sessionID: sessionKey,
                    kind: .messageUpdated,
                    message: messageWithPlanDecisions(message, summaries: summaries),
                    isStreaming: isStreaming
                )
            } else {
                MobileSyncService.shared.broadcastSessionUpdate(
                    sessionID: sessionKey,
                    kind: .messageAppended,
                    message: messageWithPlanDecisions(message, summaries: summaries),
                    isStreaming: isStreaming
                )
            }
        }
    }

    private func broadcastMobileSessionStatus(sessionID: String, kind: SessionUpdatePayload.Kind = .statusChanged) {
        guard let summary = mobileSessionSummary(for: sessionID) else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionID,
            kind: kind,
            message: nil,
            isStreaming: summary.isStreaming,
            summary: summary
        )
    }

    /// Wire representation of every `AskUserQuestion` call currently awaiting an
    /// answer, used to mirror the desktop's question queue to mobile.
    private func mobilePendingQuestionPayloads() -> [PendingQuestionPayload] {
        mobilePendingRequests.values
            .filter { $0.toolName == "AskUserQuestion" }
            .compactMap { request in
                guard let sessionId = request.sessionId,
                      let data = try? JSONEncoder().encode(request.toolInput),
                      let json = String(data: data, encoding: .utf8)
                else { return nil }
                return PendingQuestionPayload(
                    toolUseID: request.id,
                    sessionID: sessionId,
                    toolInputJSON: json
                )
            }
    }

    /// Broadcast the current `AskUserQuestion` queue to paired mobile devices.
    /// Called whenever the queue changes (a question is added or resolved) so
    /// mobile mirrors it exactly — additions and retractions alike.
    private func broadcastMobileQuestionQueue() {
        guard !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        MobileSyncService.shared.broadcastQuestionQueue(mobilePendingQuestionPayloads())
    }

    private func broadcastMobileSessionRedirect(from previousSessionID: String, to sessionID: String) {
        guard previousSessionID != sessionID,
              let summary = mobileSessionSummary(for: sessionID)
        else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionID,
            kind: .statusChanged,
            message: nil,
            isStreaming: summary.isStreaming,
            summary: summary,
            previousSessionID: previousSessionID
        )
        scheduleMobileSnapshotBroadcast()
    }

    private func mobileBranchBriefings() -> [MobileBranchBriefing] {
        let knownProjectIds = Set(projects.map(\.id))
        return threadStore.allBranchBriefingItems()
            .filter { knownProjectIds.contains($0.projectId) }
            .map {
                MobileBranchBriefing(
                    projectId: $0.projectId,
                    branch: $0.branch,
                    briefing: $0.briefing,
                    updatedAt: $0.updatedAt
                )
            }
    }

    private func mobileThreadSummaries() -> [MobileThreadSummary] {
        let knownProjectIds = Set(projects.map(\.id))
        return threadStore.allThreadSummaryItems()
            .filter { knownProjectIds.contains($0.projectId) }
            .map {
                MobileThreadSummary(
                    sessionId: $0.sessionId,
                    projectId: $0.projectId,
                    branch: $0.branch,
                    title: $0.title,
                    summary: $0.summary,
                    updatedAt: $0.updatedAt
                )
            }
    }

    private func mobileSettingsSnapshot() -> MobileSettingsSnapshot {
        let sections = availableAgentModelSections().map {
            AgentModelSection(
                id: $0.id,
                title: $0.title,
                provider: $0.provider,
                iconURL: $0.iconURL,
                models: $0.models
            )
        }
        let models = sections.flatMap(\.models)
        return MobileSettingsSnapshot(
            selectedAgentProvider: selectedAgentProvider,
            selectedModel: selectedModel,
            selectedACPClientId: selectedACPClientId,
            selectedEffort: selectedEffort,
            permissionMode: permissionMode,
            summarizationProvider: summarizationProvider.rawValue,
            summarizationProviderDisplayName: summarizationProvider.displayName,
            openAISummarizationEndpoint: openAISummarizationEndpoint,
            openAISummarizationModel: openAISummarizationModel,
            notificationsEnabled: notificationsEnabled,
            focusMode: focusMode,
            autoArchiveEnabled: autoArchiveEnabled,
            archiveRetentionDays: archiveRetentionDays,
            autoPreviewSettings: autoPreviewSettings,
            availableEfforts: ["auto"] + Self.availableEfforts,
            availableModels: models,
            modelSections: sections,
            availableSummarizationProviders: SummarizationProvider.availableCases.map {
                SummarizationProviderOption(id: $0.rawValue, displayName: $0.displayName)
            },
            openAISummarizationModels: openAISummarizationModels
        )
    }

    /// Resolve the current git branch and the local branch list for each known
    /// project. Runs the per-project git calls concurrently so a large project
    /// list doesn't serialize on disk I/O.
    private func mobileProjectBranches() async -> [ProjectBranchInfo] {
        let inputs = projects.map { (id: $0.id, path: $0.path) }
        return await withTaskGroup(of: ProjectBranchInfo?.self) { group in
            for input in inputs {
                group.addTask {
                    async let current = GitHelper.currentBranch(at: input.path)
                    async let list = GitHelper.listLocalBranches(at: input.path)
                    guard let branch = await current else { return nil }
                    let branches = await list
                    return ProjectBranchInfo(
                        projectId: input.id,
                        currentBranch: branch,
                        availableBranches: branches.isEmpty ? nil : branches
                    )
                }
            }
            var result: [ProjectBranchInfo] = []
            for await info in group {
                if let info { result.append(info) }
            }
            return result
        }
    }

    private func applyMobileSettingsUpdate(_ update: MobileSettingsUpdatePayload) {
        if let provider = update.selectedAgentProvider {
            selectedAgentProvider = provider
        }
        if let model = update.selectedModel {
            selectedModel = model
        }
        if let clientId = update.selectedACPClientId {
            selectedACPClientId = clientId
        }
        if let effort = update.selectedEffort, effort == "auto" || Self.availableEfforts.contains(effort) {
            selectedEffort = effort
        }
        if let mode = update.permissionMode {
            permissionMode = mode
        }
        if let rawProvider = update.summarizationProvider,
           let provider = SummarizationProvider(rawValue: rawProvider),
           SummarizationProvider.availableCases.contains(provider) {
            summarizationProvider = provider
        }
        if let model = update.openAISummarizationModel {
            openAISummarizationModel = model
        }
        if let enabled = update.notificationsEnabled {
            notificationsEnabled = enabled
        }
        if let enabled = update.focusMode {
            focusMode = enabled
        }
        if let enabled = update.autoArchiveEnabled {
            autoArchiveEnabled = enabled
        }
        if let days = update.archiveRetentionDays {
            archiveRetentionDays = max(1, min(365, days))
        }
        if let previews = update.autoPreviewSettings {
            autoPreviewSettings = previews
        }
    }

    /// Number of messages in one mobile history page. Mobile loads the most
    /// recent page on subscribe and requests older pages as the user scrolls up.
    static let mobileMessagePageSize = 30

    /// Encoded byte ceiling for the message slice carried in one sync frame.
    /// The relay caps a WebSocket frame at 10 MiB and the encrypted envelope
    /// inflates the plaintext by roughly a third (base64), so an oversized
    /// snapshot would have `task.send` throw and be silently dropped — leaving
    /// mobile with only the live stream and no history. Holding the message
    /// slice to 3 MiB leaves ample room for the rest of the snapshot (projects,
    /// session summaries, briefings) and the envelope overhead; older messages
    /// beyond the budget are paged in on demand via `load_more_messages`.
    static let mobileMessagePageByteBudget = 3 * 1024 * 1024

    /// Largest suffix of `messages[..<end]` that fits both the page-count and
    /// byte budgets, walking newest-first. At least one message is always
    /// returned so paging can still advance even on a pathologically large
    /// message. Returns the page and the index it starts at — a non-zero start
    /// means older messages remain.
    private func mobileMessagePage(
        from messages: [ChatMessage],
        endingAt end: Int,
        countLimit: Int
    ) -> (page: [ChatMessage], startIndex: Int) {
        let clampedEnd = min(max(end, 0), messages.count)
        guard clampedEnd > 0, countLimit > 0 else { return ([], clampedEnd) }
        let encoder = JSONEncoder()
        var startIndex = clampedEnd
        var byteCount = 0
        var index = clampedEnd - 1
        while index >= 0 {
            let size = (try? encoder.encode(messages[index]))?.count ?? 0
            let takenSoFar = clampedEnd - startIndex
            // Always accept the newest message; afterwards stop once either
            // budget would be exceeded so the frame stays under the relay cap.
            if takenSoFar > 0,
               takenSoFar >= countLimit
                || byteCount + size > Self.mobileMessagePageByteBudget {
                break
            }
            byteCount += size
            startIndex = index
            index -= 1
        }
        return (Array(messages[startIndex ..< clampedEnd]), startIndex)
    }

    /// Single-entry cache of a disk-loaded session's full message list. Mobile
    /// pages one thread at a time, so caching just the most recent one lets the
    /// snapshot and every subsequent `load_more_messages` page reuse one parse
    /// instead of re-reading the whole jsonl each time — without holding many
    /// threads in memory. Live (streaming) sessions bypass this entirely.
    private var mobileFullMessageCache: (sessionID: String, messages: [ChatMessage])?

    /// Resolve the full, cleaned message list for a session — from live stream
    /// state when available, otherwise from disk (cached). `nil` only when the
    /// session genuinely can't be located.
    private func fullMobileMessages(for resolvedID: String) async -> [ChatMessage]? {
        if let state = sessionStates[resolvedID] {
            return messagesWithPlanDecisions(
                cleanLoadedMessages(state.messages),
                summaries: state.planDecisionSummaries
            )
        }
        // Non-active session: the in-memory sidecar is absent, so pull the
        // persisted decisions from the thread store.
        let summaries = threadStore.loadPlanDecisions(sessionId: resolvedID)
        if let cache = mobileFullMessageCache, cache.sessionID == resolvedID {
            return messagesWithPlanDecisions(cache.messages, summaries: summaries)
        }
        guard let summary = allSessionSummaries.first(where: { $0.id == resolvedID }),
              let project = projects.first(where: { $0.id == summary.projectId }),
              let full = await persistence.loadFullSession(summary: summary, cwd: project.path)
        else {
            return nil
        }
        let cleaned = cleanLoadedMessages(full.messages)
        mobileFullMessageCache = (resolvedID, cleaned)
        return messagesWithPlanDecisions(cleaned, summaries: summaries)
    }

    /// Bake persisted plan decisions into `ExitPlanMode` tool results before
    /// messages are sent to mobile. Once a plan resolves, the CLI overwrites the
    /// tool result with its own follow-up text ("User has approved your plan…"),
    /// which the desktop UI sidesteps with the `planDecisionSummaries` sidecar.
    /// Mobile has no such sidecar — it reads `toolCall.result` directly — so the
    /// user-decision summary must be written onto the wire result, otherwise the
    /// mobile plan banner reappears after a decision.
    private func messagesWithPlanDecisions(
        _ messages: [ChatMessage],
        summaries: [String: String]
    ) -> [ChatMessage] {
        guard !summaries.isEmpty else { return messages }
        return messages.map { messageWithPlanDecisions($0, summaries: summaries) }
    }

    private func messageWithPlanDecisions(
        _ message: ChatMessage,
        summaries: [String: String]
    ) -> ChatMessage {
        guard !summaries.isEmpty else { return message }
        var result = message
        for block in message.blocks {
            guard let toolCall = block.toolCall,
                  PlanLogic.isExitPlanMode(toolCall),
                  let summary = summaries[toolCall.id] else { continue }
            // Skip when the result is already the user-decision string.
            if toolCall.result.map(PlanDecisionAction.isUserDecisionResult) != true {
                result.setToolResult(id: toolCall.id, result: summary, isError: false)
            }
        }
        return result
    }

    /// Build the active-session payload for a snapshot: only the most recent
    /// page of messages, plus whether older messages remain. Mobile pages the
    /// rest in via `load_more_messages` so a snapshot never carries a whole
    /// (potentially multi-MB) thread history in one frame.
    private func mobileActiveSessionPayload(
        for requestedID: String?
    ) async -> (id: String?, messages: [ChatMessage]?, hasMore: Bool) {
        guard let requestedID else { return (nil, nil, false) }
        let resolvedID = resolveCurrentSessionId(requestedID)
        guard let all = await fullMobileMessages(for: resolvedID) else {
            return (nil, nil, false)
        }
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: all.count,
            countLimit: Self.mobileMessagePageSize
        )
        return (resolvedID, page, startIndex > 0)
    }

    /// Reply to a mobile `load_more_messages` request with the page of messages
    /// immediately older than `beforeMessageID`.
    private func handleMobileLoadMoreMessages(
        _ request: LoadMoreMessagesRequestPayload,
        fromHex: String
    ) async {
        let resolvedID = resolveCurrentSessionId(request.sessionID)
        let all = await fullMobileMessages(for: resolvedID) ?? []
        guard let anchorIndex = all.firstIndex(where: { $0.id == request.beforeMessageID }) else {
            // The anchor is gone (thread changed, or never loaded). Stop paging.
            await MobileSyncService.shared.send(
                .moreMessages(MoreMessagesPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    messages: [],
                    hasMore: false
                )),
                toHex: fromHex
            )
            return
        }
        let limit = max(1, request.limit)
        let (page, startIndex) = mobileMessagePage(
            from: all,
            endingAt: anchorIndex,
            countLimit: limit
        )
        await MobileSyncService.shared.send(
            .moreMessages(MoreMessagesPayload(
                clientRequestID: request.clientRequestID,
                sessionID: request.sessionID,
                messages: page,
                hasMore: startIndex > 0
            )),
            toHex: fromHex
        )
    }

    /// Builds the change overview for the mobile "View Changes" sheet: every
    /// file edited in the thread session plus the project's uncommitted git
    /// changes. Replies with a `threadChangesResult`.
    private func handleMobileThreadChangesRequest(
        _ request: ThreadChangesRequestPayload,
        fromHex hex: String
    ) async {
        let resolvedID = resolveCurrentSessionId(request.sessionID)

        // This Turn: every file edited in the thread session (SwiftData history).
        let turnEdits = threadStore.fetchFileEdits(sessionId: resolvedID).map { edit -> SyncFileEdit in
            let summary = edit.toSummary()
            return SyncFileEdit(
                path: summary.path,
                name: summary.name,
                containsWrite: summary.containsWrite,
                hunks: summary.hunks.map {
                    SyncEditHunk(oldString: $0.oldString, newString: $0.newString)
                }
            )
        }

        func reply(ok: Bool, error: String?, uncommitted: [SyncGitChange]) async {
            await MobileSyncService.shared.send(
                .threadChangesResult(ThreadChangesResultPayload(
                    clientRequestID: request.clientRequestID,
                    sessionID: request.sessionID,
                    ok: ok,
                    errorMessage: error,
                    turnEdits: turnEdits,
                    uncommitted: uncommitted
                )),
                toHex: hex
            )
        }

        // Uncommitted: the session's project working tree.
        let projectPath = allSessionSummaries
            .first(where: { $0.id == resolvedID })
            .flatMap { summary in projects.first(where: { $0.id == summary.projectId })?.path }

        guard let projectPath, !projectPath.isEmpty else {
            await reply(ok: false, error: "This thread has no associated project folder.", uncommitted: [])
            return
        }

        guard let gitChanges = await GitHelper.uncommittedChanges(at: projectPath) else {
            await reply(ok: false, error: "This project is not a git repository.", uncommitted: [])
            return
        }

        let uncommitted = gitChanges.map { change -> SyncGitChange in
            let kind: SyncGitChangeKind = switch change.kind {
            case .staged: .staged
            case .unstaged: .unstaged
            case .untracked: .untracked
            }
            return SyncGitChange(
                displayPath: change.displayPath,
                statusChar: change.statusChar,
                kind: kind,
                unifiedDiff: change.unifiedDiff,
                truncated: change.truncated
            )
        }
        await reply(ok: true, error: nil, uncommitted: uncommitted)
    }

    /// User-triggered full reindex of every thread. Wipes cached embeddings,
    /// then re-embeds every thread. Updates `reindexProgress` so the UI can
    /// render a counter.
    func reindexAllThreads() async {
        guard reindexProgress == nil else { return }
        reindexProgress = (0, 0)
        let searchService = self.searchService
        let threadStore = self.threadStore
        let persistence = self.persistence
        await searchService.reindexAll(
            loadAll: { @MainActor in threadStore.loadAllSummaries() },
            loadFull: { @MainActor [weak self] summary -> ChatSession? in
                let cwd = self?.projects.first(where: { $0.id == summary.projectId })?.path ?? ""
                return await persistence.loadFullSession(summary: summary, cwd: cwd)
            },
            progress: { [weak self] done, total in
                Task { @MainActor in self?.reindexProgress = (done, total) }
            }
        )
        reindexProgress = nil
    }

    // MARK: - Agent Backends

    /// Looks up the `AgentBackend` for the given provider. Used by
    /// `processStream`/`cancel`/`finalize` to dispatch via the unified
    /// protocol instead of switching on the enum directly.
    func backend(for provider: AgentProvider) -> any AgentBackend {
        switch provider {
        case .claudeCode: return claude
        case .codex: return codex
        case .acp: return acp
        }
    }

    // MARK: - ACP Actions

    func loadACPClientsFromDisk() async {
        let loaded = await persistence.loadACPClients()
        acpClients = loaded
    }

    func saveACPClients() {
        let clients = acpClients
        Task { [persistence] in
            try? await persistence.saveACPClients(clients)
        }
    }

    func refreshACPRegistry(forceRefresh: Bool = false) async {
        acpRegistryLoading = true
        defer { acpRegistryLoading = false }
        let snapshotURL = persistence.acpRegistrySnapshotURL()
        if let reg = await acpRegistryService.fetchRegistry(forceRefresh: forceRefresh, snapshotURL: snapshotURL) {
            acpRegistry = reg
        }
    }

    func addACPClient(_ spec: ACPClientSpec) {
        acpClients.append(spec)
        saveACPClients()
    }

    func updateACPClient(_ spec: ACPClientSpec) {
        guard let idx = acpClients.firstIndex(where: { $0.id == spec.id }) else { return }
        acpClients[idx] = spec
        saveACPClients()
    }

    func removeACPClient(id: String) {
        if let removed = acpClients.first(where: { $0.id == id }) {
            // Clean up the on-disk install if this client owns a binary
            // under the installer's managed root.
            if case .binary(let path, _, _) = removed.launch,
               let registryId = removed.registryId,
               ACPInstallerService.isManaged(path: path)
            {
                Task.detached { await ACPInstallerService.shared.uninstall(registryId: registryId) }
            }
        }
        acpClients.removeAll { $0.id == id }
        if selectedACPClientId == id { selectedACPClientId = "" }
        saveACPClients()
    }

    /// Installs an ACP client from a registry entry. Tries the platform's
    /// declared binary distribution first (downloading and extracting it),
    /// then falls back to whatever else the registry declares (`npx`/`uvx`).
    /// After install, probes the agent (`initialize` + `session/new`) to
    /// populate the model picker from its advertised `configOptions`.
    func installACPClient(from agent: ACPRegistryAgent) async throws -> ACPClientSpec {
        let launch = try await resolveLaunch(for: agent)
        let spec = ACPClientSpec(
            registryId: agent.id,
            displayName: agent.name,
            launch: launch,
            iconURL: agent.icon
        )
        return await probedSpec(spec, agentId: agent.id)
    }

    /// Re-probes an installed client and persists the result. If the probe
    /// fails or the agent doesn't expose a model selector, the picker falls
    /// back to the built-in defaults for known registry agents.
    func refreshACPClientModels(id: String) async {
        guard let idx = acpClients.firstIndex(where: { $0.id == id }) else { return }
        let current = acpClients[idx]
        let updated = await probedSpec(current, agentId: current.registryId ?? current.id)
        if let liveIdx = acpClients.firstIndex(where: { $0.id == id }) {
            acpClients[liveIdx] = updated
            saveACPClients()
        }
    }

    private func probedSpec(_ spec: ACPClientSpec, agentId: String) async -> ACPClientSpec {
        var result = spec
        let probeCwd = NSHomeDirectory()
        do {
            if let config = try await acp.probeModels(spec: spec, cwd: probeCwd) {
                result.modelConfigId = config.configId
                result.models = config.options.map { $0.value }
                result.modelOptions = config.options
                logger.info("[ACP] probed \(result.models.count) models from \(agentId, privacy: .public) configId=\(config.configId, privacy: .public) current=\(config.currentValue ?? "nil", privacy: .public) models=[\(Self.acpModelListDescription(config.options), privacy: .public)]")
                return result
            }
            logger.info("[ACP] no model selector advertised by \(agentId, privacy: .public)")
        } catch {
            logger.warning("[ACP] model probe failed for \(agentId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Probe missed — leave the model list empty. The picker injects a
        // synthetic "Default" entry so the client is still selectable; the
        // agent uses whatever model it chooses internally.
        result.modelConfigId = nil
        result.models = []
        result.modelOptions = nil
        return result
    }

    /// Writes a freshly-discovered model list back to the matching client
    /// spec. Called from the stream loop whenever `session/new` advertises
    /// a model selector — keeps the picker in sync with what the agent
    /// actually supports without requiring a settings round-trip.
    private func applyDiscoveredACPModels(clientId: String, config: ACPModelConfig) {
        guard let idx = acpClients.firstIndex(where: { $0.id == clientId }) else { return }
        let newModels = config.options.map { $0.value }
        var updated = acpClients[idx]
        logger.info("[ACP] applying discovered models clientId=\(clientId, privacy: .public) configId=\(config.configId, privacy: .public) current=\(config.currentValue ?? "nil", privacy: .public) models=\(newModels.count) [\(Self.acpModelListDescription(config.options), privacy: .public)]")
        guard updated.models != newModels || updated.modelOptions != config.options || updated.modelConfigId != config.configId else {
            logger.info("[ACP] discovered models unchanged for clientId=\(clientId, privacy: .public)")
            return
        }
        updated.models = newModels
        updated.modelOptions = config.options
        updated.modelConfigId = config.configId
        acpClients[idx] = updated
        saveACPClients()
    }

    private static func acpModelListDescription(_ options: [ACPModelOption]) -> String {
        options.map { option in
            option.name == option.value ? option.value : "\(option.value) (\(option.name))"
        }.joined(separator: ", ")
    }

    private func resolveLaunch(for agent: ACPRegistryAgent) async throws -> ACPClientSpec.LaunchKind {
        // Prefer the platform binary; on download/extract failure, fall through.
        if let bin = agent.distribution.binary?[ACPPlatform.current] {
            do {
                let path = try await ACPInstallerService.shared.install(
                    bin, registryId: agent.id, version: agent.version
                )
                return .binary(path: path, args: bin.args ?? [], env: bin.env ?? [:])
            } catch {
                if let npx = agent.distribution.npx {
                    return .npx(package: npx.package, args: npx.args ?? [], env: npx.env ?? [:])
                }
                if let uvx = agent.distribution.uvx {
                    return .uvx(package: uvx.package, args: uvx.args ?? [], env: uvx.env ?? [:])
                }
                throw error
            }
        }
        if let npx = agent.distribution.npx {
            return .npx(package: npx.package, args: npx.args ?? [], env: npx.env ?? [:])
        }
        if let uvx = agent.distribution.uvx {
            return .uvx(package: uvx.package, args: uvx.args ?? [], env: uvx.env ?? [:])
        }
        throw ACPInstallError.noCompatibleDistribution
    }

    // MARK: - MCP Actions

    func refreshMCPServers() async {
        mcpIsLoading = true
        mcpListError = nil
        defer { mcpIsLoading = false }
        do {
            // Pass the active project so Settings can show global defaults plus
            // the effective per-project override state.
            let list = try await mcp.list(projectPath: activeProjectPath)
            // Preserve last-known status for rows that already exist so a list
            // refresh doesn't visually downgrade everything to .unknown.
            var merged: [MCPServerInfo] = []
            merged.reserveCapacity(list.count)
            for info in list {
                if let existing = mcpServers.first(where: { $0.id == info.id }) {
                    merged.append(MCPServerInfo(
                        name: info.name,
                        transport: info.transport,
                        endpoint: info.endpoint,
                        status: existing.status,
                        scope: info.scope,
                        projectPath: info.projectPath,
                        isGloballyEnabled: info.isGloballyEnabled,
                        projectOverride: info.projectOverride,
                        effectiveEnabled: info.effectiveEnabled
                    ))
                } else {
                    merged.append(info)
                }
            }
            mcpServers = merged
        } catch {
            mcpListError = error.localizedDescription
            logger.error("MCP list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func probeMCPServer(name: String) async {
        guard let info = mcpServers.first(where: { $0.name == name }) else {
            // Fall back to a name-only probe if the row hasn't loaded yet.
            await probeMCPServer(id: name, name: name, lookup: { await self.mcp.probe(name: name, projectPath: self.activeProjectPath) })
            return
        }
        await probeMCPServer(info: info)
    }

    /// Probe one specific row. Use this when the same server name appears in
    /// multiple scopes/projects (aggregated Settings list) so the right
    /// configuration is resolved.
    func probeMCPServer(info: MCPServerInfo) async {
        await probeMCPServer(id: info.id, name: info.name, lookup: { await self.mcp.probe(info: info) })
    }

    private func probeMCPServer(id: String, name: String, lookup: @escaping () async -> MCPProbeResult) async {
        guard !mcpInFlightProbes.contains(id) else { return }
        mcpInFlightProbes.insert(id)
        defer { mcpInFlightProbes.remove(id) }

        let previousStatus: MCPStatus? = mcpServers.first(where: { $0.id == id })?.status
        let result = await lookup()
        mcpProbeResults[id] = result

        let newStatus: MCPStatus = result.ok
            ? .connected
            : .failed(result.error ?? "Probe failed")

        if let idx = mcpServers.firstIndex(where: { $0.id == id }) {
            let row = mcpServers[idx]
            mcpServers[idx] = MCPServerInfo(
                name: row.name,
                transport: row.transport,
                endpoint: row.endpoint,
                status: newStatus,
                scope: row.scope,
                projectPath: row.projectPath,
                isGloballyEnabled: row.isGloballyEnabled,
                projectOverride: row.projectOverride,
                effectiveEnabled: row.effectiveEnabled
            )
        }

        // Disconnect notification: only fire on the connected→failed edge so we
        // don't spam the user on every failed re-probe.
        if case .connected = (previousStatus ?? .unknown),
           case .failed(let message) = newStatus
        {
            let notifyService = NotificationService.shared
            let serverName = name
            Task { @MainActor in
                await notifyService.postMCPDisconnected(name: serverName, error: message)
            }
        }
    }

    @discardableResult
    func addMCPServer(spec: MCPServerSpec, scope: MCPScope) async -> String? {
        do {
            try await mcp.add(spec: spec, scope: scope, projectPath: activeProjectPath)
            await refreshMCPServers()
            // Auto-probe on add so the new row shows live status and tool list
            // without the user clicking Test.
            await probeMCPServer(name: spec.name)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func removeMCPServer(name: String, scope: MCPScope) async -> String? {
        do {
            try await mcp.remove(name: name, scope: scope)
            // Clear the probe entry that belonged to the removed row. The id
            // shape is `<scope>:[<projectPath>:]<name>` — drop any whose name
            // suffix and scope prefix match what we just removed.
            let scopePrefix = "\(scope.rawValue):"
            mcpProbeResults = mcpProbeResults.filter { key, _ in
                !(key.hasPrefix(scopePrefix) && key.hasSuffix(":\(name)"))
            }
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setMCPServerGlobalEnabled(name: String, enabled: Bool) async -> String? {
        do {
            try await mcp.setGlobalEnabled(name: name, enabled: enabled)
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func setMCPServerProjectOverride(name: String, override: MCPProjectOverride) async -> String? {
        guard let activeProjectPath else {
            return "No active project selected."
        }
        do {
            try await mcp.setProjectOverride(name: name, projectPath: activeProjectPath, override: override)
            await refreshMCPServers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Spawn the periodic MCP probe loop. Idempotent.
    func startMCPPeriodicProbe() {
        guard mcpPeriodicProbeTask == nil else { return }
        mcpPeriodicProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppState.mcpPeriodicProbeInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshAndProbeAllMCPServers()
            }
        }
    }

    /// Refresh the MCP server list and probe every server concurrently.
    /// Used at app launch (and on a 5-minute timer) so the Settings sheet shows
    /// live status without the user having to click "Test" on each row.
    func refreshAndProbeAllMCPServers() async {
        await refreshMCPServers()
        let snapshot = mcpServers
        guard !snapshot.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for info in snapshot {
                group.addTask { [weak self] in
                    await self?.probeMCPServer(info: info)
                }
            }
        }
    }

    // MARK: - Private State

    // MARK: - Window-Scoped Session State Accessors

    func streamState(in window: WindowState) -> SessionStreamState {
        sessionStates[window.currentSessionId ?? window.newSessionKey] ?? SessionStreamState()
    }

    func messages(in window: WindowState) -> [ChatMessage] {
        streamState(in: window).messages
    }

    /// File edits accumulated across this thread, sourced from SwiftData.
    /// Returns an empty array for a not-yet-persisted (placeholder) session.
    func threadFileEdits(in window: WindowState) -> [FileEditSummary] {
        let key = window.currentSessionId ?? window.newSessionKey
        return threadStore.fetchFileEdits(sessionId: key).map { $0.toSummary() }
    }

    func isStreaming(in window: WindowState) -> Bool {
        streamState(in: window).isStreaming
    }

    func isThinking(in window: WindowState) -> Bool {
        streamState(in: window).isThinking
    }

    func streamingStartDate(in window: WindowState) -> Date? {
        streamState(in: window).streamingStartDate
    }

    func activeModelName(in window: WindowState) -> String? {
        streamState(in: window).activeModelName
    }

    func lastTurnContextUsedPercentage(in window: WindowState) -> Double? {
        streamState(in: window).lastTurnContextUsedPercentage
    }

    func sessionCostUsd(in window: WindowState) -> Double {
        streamState(in: window).costUsd
    }

    func sessionTurns(in window: WindowState) -> Int {
        streamState(in: window).turns
    }

    func sessionInputTokens(in window: WindowState) -> Int {
        streamState(in: window).inputTokens
    }

    func sessionOutputTokens(in window: WindowState) -> Int {
        streamState(in: window).outputTokens
    }

    func sessionCacheCreationTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheCreationTokens
    }

    func sessionCacheReadTokens(in window: WindowState) -> Int {
        streamState(in: window).cacheReadTokens
    }

    func sessionDurationMs(in window: WindowState) -> Double {
        streamState(in: window).durationMs
    }

    func currentSession(in window: WindowState) -> ChatSession? {
        guard let id = window.currentSessionId else { return nil }
        guard let summary = allSessionSummaries.first(where: { $0.id == id }) else { return nil }
        return summary.makeSession()
    }

    /// Check whether a given session is streaming in the background (not foreground) of this window
    func isBackgroundStreaming(_ sessionId: String, in window: WindowState) -> Bool {
        guard sessionId != (window.currentSessionId ?? window.newSessionKey) else { return false }
        return sessionStates[sessionId]?.isStreaming ?? false
    }

    /// Returns the set of session IDs currently streaming in the background of this window.
    func backgroundStreamingSessionIds(in window: WindowState) -> Set<String> {
        let currentKey = window.currentSessionId ?? window.newSessionKey
        return Set(sessionStates.compactMap { key, state in
            (state.isStreaming && key != currentKey) ? key : nil
        })
    }

    /// Derive a UI status for the chat row in the project sidebar.
    func chatStatus(forSessionId id: String, in window: WindowState) -> ChatStatus {
        if window.pendingPermissions.contains(where: { $0.sessionId == id }) {
            return .awaitingPermission
        }
        if let state = sessionStates[id] {
            if state.isStreaming { return .streaming }
            if state.hasUncheckedCompletion { return .done }
        }
        return .idle
    }

    func todoProgress(forSessionId id: String) -> ChatTodoProgress? {
        if let messages = sessionStates[id]?.messages,
           let todos = TodoExtractor.latest(in: messages)
        {
            return ChatTodoProgress(todos: todos)
        }

        guard let snapshot = threadStore.fetchTodoSnapshot(sessionId: id), snapshot.total > 0 else {
            return nil
        }

        return ChatTodoProgress(
            done: snapshot.done,
            total: snapshot.total,
            inProgress: snapshot.inProgress > 0
        )
    }

    // MARK: - Initialization

    /// Once per app launch — start services and load shared data
    func initialize() async {
        ThemeStore.shared.current = selectedTheme
        ThemeStore.shared.fontSizeAdjustment = fontSizeAdjustment
        ThemeStore.shared.messageFontSizeAdjustment = messageFontSizeAdjustment

        // Supply MobileSyncService with desktop-side context for the mobile
        // job Live Activity and home-screen widget pushes.
        MobileSyncService.shared.projectNameResolver = { [weak self] id in
            self?.projects.first { $0.id == id }?.name
        }
        MobileSyncService.shared.usageSnapshotProvider = { [weak self] in
            (self?.latestRateLimitUsage?.fiveHourPercent,
             self?.latestCodexRateLimitUsage?.fiveHourPercent)
        }

        await refreshAgentInstallations()

        projects = await persistence.loadProjects()
        var seenPaths = Set<String>()
        let deduplicated = projects.filter { seenPaths.insert($0.path).inserted }
        if deduplicated.count != projects.count {
            projects = deduplicated
            try? await persistence.saveProjects(projects)
        }

        if let cachedUser = await persistence.loadGitHubUser() {
            gitHubUser = cachedUser
            isLoggedIn = true
            _ = await github.loadToken()
        }

        customRepos = await persistence.loadCustomRepos()
        marketplaceCustomSources = await marketplace.customSources()

        // Sidebar threads are now sourced from the local SwiftData store.
        // CLI session files are no longer surfaced in the sidebar list — the
        // CLI is still the transcript backend (replay on thread open), but
        // it does not drive thread discovery.
        allSessionSummaries = threadStore.loadAllSummaries()
        autoArchiveExpiredSessionsIfNeeded()
        purgeStaleBranchBriefingsIfNeeded()

        persistedQueues = threadStore.loadAllQueues()

        if claudeInstalled || codexInstalled, !onboardingCompleted {
            onboardingCompleted = true
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        }

        // Hydrate ACP state (clients + cached registry) early so the model picker
        // and Settings tab don't flash empty on first open.
        await loadACPClientsFromDisk()
        Task { await self.refreshACPRegistry(forceRefresh: false) }

        permissionMode = Self.readPermissionModeFromSettings()

        do {
            try await permission.start()
        } catch {
            logger.error("Failed to start permission server: \(error.localizedDescription)")
        }

        // Warm MCP server statuses in the background so the Settings sheet
        // shows live connection results without the user clicking "Test".
        Task { [weak self] in
            await self?.refreshAndProbeAllMCPServers()
        }

        // Warm the rate-limit usage so the menu-bar label has data before the
        // popover is opened. RateLimitService caches for 5 minutes internally.
        Task { [weak self] in
            await self?.refreshRateLimitUsage()
            await self?.refreshCodexRateLimitUsage()
        }

        // Recurring probe so disconnected MCP servers surface promptly even
        // when the user isn't actively interacting with the Settings tab.
        startMCPPeriodicProbe()

        // Permission request routing is handled per-window in initializeWindow's listener.

        isInitialized = true
    }

    func refreshAgentInstallations() async {
        let claudeBinary = await claude.findClaudeBinary()
        claudeBinaryPath = claudeBinary
        claudeInstalled = claudeBinary != nil
        claudeVersion = nil

        if claudeBinary != nil {
            do {
                claudeVersion = try await claude.checkVersion()
            } catch {
                logger.warning("Failed to fetch Claude CLI version: \(error.localizedDescription)")
            }
        }

        let codexBinary = await codex.findCodexBinary()
        codexBinaryPath = codexBinary
        codexInstalled = codexBinary != nil
        codexVersion = nil

        if codexBinary != nil {
            do {
                codexVersion = try await codex.checkVersion()
                codexModels = await codex.fetchModels()
                logger.info("Codex CLI detected; fetched \(self.codexModels.count) Codex models")
                if codexModels.isEmpty {
                    logger.warning("Codex model discovery returned empty; using built-in Codex fallback models")
                }
                Task { [weak self] in
                    await self?.refreshCodexRateLimitUsage()
                }
            } catch {
                logger.warning("Failed to fetch Codex CLI version or models: \(error.localizedDescription)")
            }
        } else {
            codexModels = []
            logger.info("Codex CLI not detected; Codex model list cleared")
        }
    }

    func refreshOpenAISummarizationModels() async {
        let endpoint = openAISummarizationEndpoint
        let apiKey = openAISummarizationAPIKey

        isLoadingOpenAISummarizationModels = true
        openAISummarizationModelsError = nil
        defer { isLoadingOpenAISummarizationModels = false }

        do {
            let models = try await openAISummarization.fetchModels(endpoint: endpoint, apiKey: apiKey)
            openAISummarizationModels = models
            if openAISummarizationModel.isEmpty || !models.contains(openAISummarizationModel) {
                openAISummarizationModel = models.first ?? ""
            }
        } catch {
            openAISummarizationModelsError = error.localizedDescription
            logger.warning("Failed to fetch OpenAI summarization models: \(error.localizedDescription)")
        }
    }

    /// Per-window initialization — restore selected project and load session history
    func initializeWindow(_ window: WindowState, selectingProjectId: UUID? = nil) async {
        // Subscribe to permission broadcasts — appends requests to this window's pendingPermissions.
        // subscribe() issues a window-exclusive stream, so events are not stolen across multiple windows.
        Task { [weak self, weak window] in
            guard let self else { return }
            let (_, stream) = await self.permission.subscribe()
            for await request in stream {
                guard !Task.isCancelled else { break }
                guard let window else { break }
                if !window.pendingPermissions.contains(where: { $0.id == request.id }) {
                    window.pendingPermissions.append(request)
                    mobilePendingRequests[request.id] = request
                    let projectName = window.selectedProject?.name
                    let projectId = window.selectedProject?.id
                    let sessionId = window.currentSessionId
                    let toolName = request.toolName
                    if let requestSessionId = request.sessionId {
                        broadcastMobileSessionStatus(sessionID: requestSessionId)
                    }
                    if toolName == "AskUserQuestion" {
                        broadcastMobileQuestionQueue()
                    }
                    // Auto-present the question sheet only when the user is actively viewing
                    // the thread the question belongs to. Otherwise it stays in the queue
                    // (yellow dot in sidebar + banner) so the user can decide when to answer.
                    if toolName == "AskUserQuestion",
                       window.presentedPermissionId == nil,
                       let qSession = request.sessionId,
                       qSession == window.currentSessionId
                    {
                        window.presentedPermissionId = request.id
                    }
                    Task { @MainActor in
                        if toolName == "AskUserQuestion" {
                            await NotificationService.shared.postQuestionNeeded(
                                projectName: projectName,
                                projectId: projectId,
                                sessionId: sessionId
                            )
                        } else {
                            await NotificationService.shared.postPermissionNeeded(
                                toolName: toolName,
                                projectName: projectName,
                                projectId: projectId,
                                sessionId: sessionId
                            )
                        }
                    }
                }
            }
        }

        // Install the AskUserQuestion handlers. The question sheet calls submit when the
        // user finishes answering, and skip when they dismiss without answering.
        window.submitQuestionAnswersHandler = { [weak self, weak window] toolUseId, answers in
            guard let self, let window else { return }
            Task { await self.respondToAskUserQuestion(toolUseId: toolUseId, answers: answers, in: window) }
        }
        window.skipQuestionHandler = { [weak self, weak window] toolUseId in
            guard let self, let window else { return }
            Task { await self.skipAskUserQuestion(toolUseId: toolUseId, in: window) }
        }

        // Install the plan-card decision handler. The buttons on `PlanCardView` route
        // through here to resolve the ExitPlanMode hook and apply any follow-up mode change.
        window.planDecisionHandler = { [weak self, weak window] toolUseId, action in
            guard let self, let window else { return }
            Task { await self.respondToPlanDecision(toolUseId: toolUseId, action: action, in: window) }
        }

        // Hydrate per-window draft queues from disk-persisted queues so messages
        // typed-while-streaming survive an app relaunch.
        for (key, queue) in persistedQueues where window.draftQueues[key] == nil {
            window.draftQueues[key] = queue
        }

        if let projectId = selectingProjectId,
           let project = projects.first(where: { $0.id == projectId })
        {
            selectProject(project, in: window)
        } else if let savedId = UserDefaults.standard.string(forKey: "selectedProjectId"),
                  let uuid = UUID(uuidString: savedId),
                  let project = projects.first(where: { $0.id == uuid })
        {
            selectProject(project, in: window)
        } else if let first = projects.first {
            selectProject(first, in: window)
        }

        // Show the briefing as the landing view on launch, even after restoring a project.
        // `selectProject` clears `showingBriefing` for normal switches; re-enable here so the
        // user lands on the briefing dashboard rather than a fresh chat.
        window.showingBriefing = true

        window.isInitialized = true
    }

    // MARK: - ChatBridge Setup

    /// Configures a `ChatBridge`'s action handlers and starts an observation loop that keeps
    /// the bridge's state properties in sync with the underlying `sessionStates`.
    func setupChatBridge(_ bridge: ChatBridge, for window: WindowState) {
        registerLiveWindow(window)
        bridge.sendHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.send(in: window)
        }
        bridge.cancelStreamingHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.cancelStreaming(in: window)
        }
        bridge.sendSlashCommandHandler = { [weak self, weak window] command in
            guard let self, let window else { return }
            await self.sendSlashCommand(command, in: window)
        }
        bridge.runTerminalCommandHandler = { [weak self, weak window] command in
            guard let self, let window else { return }
            await self.runTerminalCommand(command, in: window)
        }
        bridge.editAndResendHandler = { [weak self, weak window] messageId, newContent in
            guard let self, let window else { return }
            await self.editAndResend(messageId: messageId, newContent: newContent, in: window)
        }
        bridge.fetchRateLimitHandler = { [weak self] provider in
            await self?.rateLimitUsage(for: provider)
        }
        bridge.setSessionProviderHandler = { [weak self, weak window] provider in
            guard let self, let window else { return }
            self.setSessionProvider(provider, in: window)
        }
        bridge.togglePlanModeHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            self.toggleSessionPlanMode(in: window)
        }
        bridge.enqueueMessageHandler = { [weak self, weak window] text, attachments in
            guard let self, let window else { return }
            self.enqueueMessage(text: text, attachments: attachments, in: window)
        }
        bridge.removeQueuedMessageHandler = { [weak self, weak window] id in
            guard let self, let window else { return }
            self.removeQueuedMessage(id: id, in: window)
        }
        bridge.dequeueNextForFlushHandler = { [weak self, weak window] in
            guard let self, let window else { return nil }
            return self.dequeueNextForFlush(in: window)
        }
        bridge.sendQueuedNowHandler = { [weak self, weak window] id in
            guard let self, let window else { return }
            await self.sendQueuedNow(id: id, in: window)
        }
        bridge.sendAllQueuedAsOneHandler = { [weak self, weak window] in
            guard let self, let window else { return }
            await self.sendAllQueuedAsOne(in: window)
        }

        startBridgeObservation(bridge, for: window)
    }

    /// Runs a reactive observation loop: reads AppState + WindowState properties into the bridge,
    /// then re-registers after each change. Stops when the bridge or window is deallocated.
    private func startBridgeObservation(_ bridge: ChatBridge, for window: WindowState) {
        // Streaming state and global settings are observed in separate loops so that frequent
        // streaming updates don't trigger settings re-pushes (and vice versa).
        func observeStream() {
            withObservationTracking {
                let state = streamState(in: window)
                if bridge.messages.count != state.messages.count || bridge.isLoadingFromDisk != state.isLoadingFromDisk {
                    self.logger.info("[Bridge.observe] push sid=\(window.currentSessionId ?? "<nil>", privacy: .public) messages \(bridge.messages.count)→\(state.messages.count) loading \(bridge.isLoadingFromDisk)→\(state.isLoadingFromDisk) streaming=\(state.isStreaming)")
                }
                bridge.messages = state.messages
                bridge.isStreaming = state.isStreaming
                bridge.isThinking = state.isThinking
                bridge.isLoadingFromDisk = state.isLoadingFromDisk
                bridge.streamingStartDate = state.streamingStartDate
                bridge.liveOutputTokens = state.currentTurnOutputTokens
                bridge.lastTurnContextUsedPercentage = state.lastTurnContextUsedPercentage
                let selection = effectiveModelSelection(in: window)
                let provider = selection.provider
                let currentModel = selection.model
                bridge.agentProvider = provider
                bridge.modelDisplayName = modelDisplayName(for: currentModel, provider: provider, in: window)
                bridge.sessionStats = ChatSessionStats(
                    costUsd: state.costUsd,
                    inputTokens: state.inputTokens,
                    outputTokens: state.outputTokens,
                    cacheCreationTokens: state.cacheCreationTokens,
                    cacheReadTokens: state.cacheReadTokens,
                    durationMs: state.durationMs,
                    turns: state.turns
                )
                bridge.planDecisionSummaries = state.planDecisionSummaries
            } onChange: {
                Task { @MainActor in observeStream() }
            }
        }
        func observeSettings() {
            withObservationTracking {
                bridge.autoPreviewSettings = self.autoPreviewSettings
                bridge.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                bridge.claudeVersion = self.claudeVersion
                bridge.codexVersion = self.codexVersion
            } onChange: {
                Task { @MainActor in observeSettings() }
            }
        }
        Task { @MainActor in observeStream() }
        Task { @MainActor in observeSettings() }
    }

    // MARK: - Edit & Resend

    func editAndResend(messageId: UUID, newContent: String, in window: WindowState) async {
        let key = window.currentSessionId ?? window.newSessionKey
        var snapshot = sessionStates[key]?.messages ?? []
        guard let index = snapshot.firstIndex(where: { $0.id == messageId }),
              snapshot[index].role == .user else { return }

        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        snapshot.removeSubrange((index + 1)...)
        snapshot[index].content = trimmed

        window.currentSessionId = nil
        sessionStates.removeValue(forKey: window.newSessionKey)
        await sendPrompt(trimmed, skipAppendingUserMessage: true, initialMessages: snapshot, in: window)
    }

    // MARK: - Send Message

    func send(in window: WindowState) async {
        let prompt = window.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = window.attachments
        guard !prompt.isEmpty || !currentAttachments.isEmpty else { return }

        // S2: warn (in logs) if another process touched the same jsonl very
        // recently — likely a `claude` running in the terminal on the same
        // session. We don't block, but the operator can spot it after the fact.
        if effectiveModelSelection(in: window).provider == .claudeCode,
           let sid = window.currentSessionId,
           let cwd = window.selectedProject?.path,
           cliStore.detectExternalActivity(sid: sid, cwd: cwd, withinSeconds: 5)
        {
            logger.warning("Session \(sid, privacy: .public) jsonl was modified within 5s — another claude process may be active")
        }

        if currentAttachments.isEmpty, await handleNativeSlashCommand(prompt, in: window) {
            window.inputText = ""
            return
        }

        window.inputText = ""
        window.draftTexts.removeValue(forKey: draftKey(for: window))
        window.attachments = []

        let (resolvedAttachments, tempFilePaths) = AttachmentFactory.resolvingClipboardImages(currentAttachments)
        let fullPrompt = buildPromptWithAttachments(prompt, attachments: resolvedAttachments)

        await sendPrompt(fullPrompt, displayText: prompt, attachments: resolvedAttachments,
                         tempFilePaths: tempFilePaths, in: window)
    }

    /// Slash commands handled natively. Returns true if handled.
    private func handleNativeSlashCommand(_ text: String, in window: WindowState) async -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.split(separator: " ", maxSplits: 1)
        let command = parts.first.map { String($0.dropFirst()) } ?? ""

        switch command {
        case "clear":
            startNewChat(in: window)
            return true
        case "model":
            if parts.count > 1 {
                let arg = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                let flattened = availableAgentModelSections().flatMap(\.models)
                let matched = flattened.first { $0.id.lowercased() == arg }
                    ?? flattened.first { arg.contains($0.id.lowercased()) }
                setSessionModel(matched?.id ?? arg, provider: matched?.provider, in: window)
            } else {
                window.showModelPicker = true
            }
            return true
        case "effort":
            if parts.count > 1 {
                let arg = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                setSessionEffort(Self.availableEfforts.contains(arg) ? arg : nil, in: window)
            } else {
                window.showEffortPicker = true
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Send Slash Command

    func sendSlashCommand(_ command: String, in window: WindowState) async {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if await handleNativeSlashCommand(trimmed, in: window) { return }

        let baseName = trimmed.split(separator: " ", maxSplits: 1)
            .first.map { String($0.dropFirst()) } ?? ""

        let isInteractive = SlashCommandRegistry.commands
            .first { $0.name == baseName }?.isInteractive ?? false

        if isInteractive {
            await sendInteractiveCommand(trimmed, in: window)
        } else {
            await sendPrompt(trimmed, in: window)
        }
    }

    private func sendInteractiveCommand(_ command: String, in window: WindowState) async {
        let title = command.trimmingCharacters(in: .whitespaces)
        await launchTerminal(title: title, initialCommand: command, in: window)
    }

    func runTerminalCommand(_ command: String, in window: WindowState) async {
        let title = command.trimmingCharacters(in: .whitespaces)
        await launchTerminal(title: title, initialCommand: command, rawShell: true, in: window)
    }

    func openTerminal(in window: WindowState) async {
        // Right sidebar visibility lives in UserDefaults (read via @AppStorage
        // in views). Writing here triggers those views to update.
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.showRightSidebar
        if defaults.bool(forKey: key), window.inspectorTab == .terminal {
            defaults.set(false, forKey: key)
        } else {
            window.inspectorTab = .terminal
            defaults.set(true, forKey: key)
        }
    }

    private func launchTerminal(
        title: String,
        initialCommand: String? = nil,
        reportToChat: Bool = true,
        rawShell: Bool = false,
        in window: WindowState
    ) async {
        guard let project = window.selectedProject else {
            handleError(AppError.noProjectSelected, in: window)
            return
        }

        let arguments: [String]
        if rawShell {
            arguments = ["-il"]
        } else {
            guard let binary = await claude.findClaudeBinary() else {
                handleError(AppError.claudeNotInstalled, in: window)
                return
            }
            arguments = ["-ilc", binary]
        }

        window.interactiveTerminal = InteractiveTerminalState(
            title: title,
            executable: "/bin/zsh",
            arguments: arguments,
            currentDirectory: project.path,
            initialCommand: initialCommand,
            reportToChat: reportToChat
        )
    }

    func dismissInteractiveTerminal(exitCode: Int32, in window: WindowState) {
        guard let terminal = window.interactiveTerminal else { return }
        window.interactiveTerminal = nil

        guard terminal.reportToChat else { return }

        let key = window.currentSessionId ?? window.newSessionKey
        let wasFirstUserMessage = (sessionStates[key]?.messages.filter { $0.role == .user }.count ?? 0) == 0
        updateState(key) { state in
            state.messages.append(ChatMessage(role: .user, content: terminal.title))
            let result = exitCode == 0 ? "Done" : "exit code: \(exitCode)"
            let toolCall = ToolCall(
                id: UUID().uuidString,
                name: InteractiveTerminalState.toolName,
                input: ["command": .string(terminal.title)],
                result: result,
                isError: exitCode != 0
            )
            state.messages.append(ChatMessage(role: .assistant, blocks: [.toolCall(toolCall)]))
        }
        if wasFirstUserMessage, !(sessionStates[key]?.titleGenerationTriggered ?? false) {
            updateState(key) { $0.titleGenerationTriggered = true }
            Task { [weak self] in
                guard let self else { return }
                await self.maybeGenerateLLMTitle(for: key)
            }
        }
        Task { await saveCurrentSession(in: window) }
    }

    // MARK: - Shared Send Logic

    @discardableResult
    private func sendPrompt(
        _ prompt: String,
        displayText: String? = nil,
        attachments: [Attachment] = [],
        skipAppendingUserMessage: Bool = false,
        initialMessages: [ChatMessage]? = nil,
        tempFilePaths: [String] = [],
        in window: WindowState
    ) async -> UUID? {
        guard let project = window.selectedProject else {
            handleError(AppError.noProjectSelected, in: window)
            return nil
        }

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        let streamId = UUID()
        let isNewSession = window.currentSessionId == nil
        let isPending = window.currentSessionId.map { window.pendingPlaceholderIds.contains($0) } ?? false
        let cliSessionId: String? = (isNewSession || isPending) ? nil : window.currentSessionId

        if isNewSession {
            let tempId = "pending-\(streamId.uuidString)"
            window.currentSessionId = tempId
            window.insertPendingPlaceholder(tempId)
            let snapSelection = effectiveModelSelection(in: window)
            let snapProvider = snapSelection.provider
            let snapModel = snapSelection.model
            window.sessionAgentProvider = snapProvider
            window.sessionModel = snapModel
            let snapEffort = window.sessionEffort
            let snapPermission = window.sessionPermissionMode
            let pendingWorktreePath = window.pendingWorktreePath
            let pendingWorktreeBranch = window.pendingWorktreeBranch
            updateState(tempId) { state in
                state.agentProvider = snapProvider
                state.model = snapModel
                state.effort = snapEffort
                state.permissionMode = snapPermission
                state.worktreePath = pendingWorktreePath
                state.worktreeBranch = pendingWorktreeBranch
            }
            window.pendingWorktreePath = nil
            window.pendingWorktreeBranch = nil
        }

        let sessionKey = window.currentSessionId!

        // Apply initialMessages if provided
        if let initial = initialMessages {
            updateState(sessionKey) { $0.messages = initial }
        }

        let wasFirstUserMessage = (sessionStates[sessionKey]?.messages.filter { $0.role == .user }.count ?? 0) == 0
        if !skipAppendingUserMessage {
            updateState(sessionKey) { state in
                state.messages.append(ChatMessage(
                    role: .user,
                    content: displayText ?? prompt,
                    attachments: attachments
                ))
                state.inFlightUserAttachments = attachments
            }
        }

        // Insert the placeholder summary before kicking off title generation —
        // the Task below awaits and the lookup in maybeGenerateLLMTitle would
        // otherwise race the insertion at line ~1168 and bail with "no summary".
        if isNewSession {
            let initialTitle = ChatSession.placeholderTitle(from: displayText ?? prompt)
            let selection = effectiveModelSelection(in: window)
            let provider = selection.provider
            let placeholder = ChatSession(
                id: sessionKey,
                projectId: project.id,
                title: initialTitle,
                messages: [],
                agentProvider: provider,
                model: selection.model,
                origin: provider.defaultSessionOrigin,
                worktreePath: sessionStates[sessionKey]?.worktreePath,
                worktreeBranch: sessionStates[sessionKey]?.worktreeBranch
            )
            allSessionSummaries.insert(placeholder.summary, at: 0)
            threadStore.upsert(placeholder.summary)
        }

        // Kick off LLM title generation as soon as the first user message lands —
        // the rename runs concurrently with the stream so the sidebar title updates
        // without waiting for the assistant to reply.
        if wasFirstUserMessage,
           !skipAppendingUserMessage,
           !(sessionStates[sessionKey]?.titleGenerationTriggered ?? false)
        {
            updateState(sessionKey) { $0.titleGenerationTriggered = true }
            let titleKey = sessionKey
            Task { [weak self] in
                guard let self else { return }
                await self.maybeGenerateLLMTitle(for: titleKey)
            }
        }

        updateState(sessionKey) { state in
            state.isStreaming = true
            state.hasUncheckedCompletion = false
            state.activeStreamId = streamId
            state.streamingStartDate = Date()
            state.currentTurnOutputTokensByMessage.removeAll(keepingCapacity: true)
            state.currentTurnOutputTokensUnkeyed = 0
        }
        broadcastMobileSessionStatus(sessionID: sessionKey, kind: .streamingStarted)

        let basePermissionMode = window.sessionPermissionMode ?? permissionMode
        // Plan-mode boolean overrides the dropdown for the CLI `--permission-mode` flag only.
        // The dropdown choice is preserved and re-applied automatically once plan-mode is toggled back off.
        let cliPermissionMode: PermissionMode = window.sessionPlanMode ? .plan : basePermissionMode
        // PermissionServer registration uses the dropdown value directly so an explicit Auto
        // choice continues to auto-approve hook-matched tools while plan mode is on.
        // ExitPlanMode is always exempt from auto-approve (see PermissionServer.autoApproveReason),
        // so the plan card still surfaces.
        let hookSessionMode = basePermissionMode
        let launchAgentProvider = sessionStates[sessionKey]?.agentProvider
            ?? window.sessionAgentProvider
            ?? selectedAgentProvider
        var hookSettingsPath: String?
        if launchAgentProvider == .claudeCode, !cliPermissionMode.skipsHookPipeline {
            do {
                hookSettingsPath = try await permission.writeHookSettingsFile()
            } catch {
                logger.error("Failed to write hook settings: \(error.localizedDescription)")
            }
        }

        // Resume already has the sid; new sessions register on first system event.
        if let sid = cliSessionId {
            await permission.registerSession(sid: sid, projectKey: project.path, mode: hookSessionMode)
        }

        if !isNewSession {
            await saveCurrentSession(in: window)
        }

        let effectiveCwd = sessionStates[sessionKey]?.worktreePath
            ?? allSessionSummaries.first(where: { $0.id == sessionKey })?.worktreePath
            ?? project.path
        let selection = effectiveModelSelection(in: window)
        let effectiveProvider = sessionStates[sessionKey]?.agentProvider ?? selection.provider
        let effectiveModel = sessionStates[sessionKey]?.model ?? selection.model

        let task = Task { [weak self, window] in
            guard let self else { return }
            await self.processStream(
                streamId: streamId,
                prompt: prompt,
                cwd: effectiveCwd,
                cliSessionId: cliSessionId,
                internalSessionKey: sessionKey,
                agentProvider: effectiveProvider,
                model: effectiveModel,
                effort: window.sessionEffort ?? (self.selectedEffort == "auto" ? nil : self.selectedEffort),
                hookSettingsPath: hookSettingsPath,
                permissionMode: cliPermissionMode,
                hookSessionMode: hookSessionMode,
                projectId: project.id,
                window: window
            )
            for path in tempFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        sessionStates[sessionKey, default: SessionStreamState()].streamTask = task
        return streamId
    }

    // MARK: - Stream Processing

    private func stateForSession(_ key: String) -> SessionStreamState {
        sessionStates[key] ?? SessionStreamState()
    }

    private func updateState(_ key: String, _ mutate: (inout SessionStreamState) -> Void) {
        let prevMessages = sessionStates[key]?.messages ?? []
        let prevThinking = sessionStates[key]?.isThinking ?? false
        guard var state = sessionStates[key] else {
            var fresh = SessionStreamState()
            mutate(&fresh)
            sessionStates[key] = fresh
            broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: fresh.messages, isStreaming: fresh.isStreaming)
            broadcastMobileThinkingChange(sessionKey: key, prev: prevThinking, next: fresh.isThinking, isStreaming: fresh.isStreaming)
            return
        }
        mutate(&state)
        sessionStates[key] = state
        broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: state.messages, isStreaming: state.isStreaming)
        broadcastMobileThinkingChange(sessionKey: key, prev: prevThinking, next: state.isThinking, isStreaming: state.isStreaming)
    }

    /// Mirror `isThinking` transitions to paired mobile devices so the remote
    /// streaming indicator can show a "Thinking…" label. Only fires on an
    /// actual change — the flag flips repeatedly within a turn and we don't
    /// want to flood the relay with redundant updates.
    private func broadcastMobileThinkingChange(sessionKey: String, prev: Bool, next: Bool, isStreaming: Bool) {
        guard prev != next, !MobileSyncService.shared.pairedDevices.isEmpty else { return }
        MobileSyncService.shared.broadcastSessionUpdate(
            sessionID: sessionKey,
            kind: .statusChanged,
            message: nil,
            isStreaming: isStreaming,
            isThinking: next
        )
    }

    private func finalizeStreamSession(
        for sessionKey: String,
        extraMutations: ((inout SessionStreamState) -> Void)? = nil
    ) {
        flushPendingUpdates(for: sessionKey)
        updateState(sessionKey) { state in
            state.flushTask?.cancel()
            state.flushTask = nil
            state.isStreaming = false
            state.isThinking = false
            state.needsNewMessage = false
            state.activeStreamId = nil
            state.streamTask = nil
            state.activeToolId = nil
            state.activeToolInputBuffer = ""
            state.textDeltaBuffer = ""
            state.pendingToolResults.removeAll()

            extraMutations?(&state)

            if let idx = state.messages.indices.reversed().first(where: {
                state.messages[$0].role == .assistant && state.messages[$0].isStreaming
            }) {
                state.messages[idx].isStreaming = false
                state.messages[idx].isResponseComplete = true
                state.messages[idx].finalizeToolCalls()
                if let start = state.streamingStartDate {
                    state.messages[idx].duration = Date().timeIntervalSince(start)
                }
                Self.stripNoOpText(at: idx, in: &state.messages)
            }
            state.streamingStartDate = nil
        }
        broadcastMobileSessionStatus(sessionID: sessionKey, kind: .streamingFinished)
        Task { @MainActor [weak self] in
            await self?.flushNextQueuedMessageIfNeeded(sessionID: sessionKey)
        }
    }

    // MARK: - Stream Completion (cross-project MCP)

    /// Record that the stream `streamId` finished. Stored in
    /// `pendingStreamCompletions` for any `awaitStreamCompletion(...)` caller
    /// (currently `ide__send_to_thread`) to pick up. Latest call wins, except
    /// we don't overwrite a success with an error from the fallback path.
    private func recordStreamCompletion(
        streamId: UUID,
        sessionId: String,
        assistantText: String,
        error: String?
    ) {
        pendingStreamCompletions[streamId] = StreamCompletion(
            sessionId: sessionId,
            assistantText: assistantText,
            error: error
        )
    }

    /// Wait up to `timeout` seconds for the stream identified by `streamId`
    /// to record a completion. Polls every 100ms — MainActor serialization
    /// means the recorder fires between sleeps. Returns the completion if
    /// one arrived in time, otherwise `nil`.
    func awaitStreamCompletion(streamId: UUID, timeout: TimeInterval) async -> StreamCompletion? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let completion = pendingStreamCompletions.removeValue(forKey: streamId) {
                return completion
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return pendingStreamCompletions.removeValue(forKey: streamId)
    }

    /// Discard a recorded completion. Called by long-running `wait_for_response=false`
    /// MCP sends so the dictionary doesn't grow unbounded with abandoned results.
    func discardStreamCompletion(streamId: UUID) {
        pendingStreamCompletions.removeValue(forKey: streamId)
    }

    // MARK: - Cross-Project Send (used by ide__send_to_thread)

    struct CrossProjectSendResult: Sendable {
        let threadId: String
        let projectId: UUID
        let done: Bool
        let assistantText: String
        let error: String?
    }

    enum CrossProjectSendError: Error, LocalizedError {
        case unknownProject(UUID)
        case unknownThread(String)

        var errorDescription: String? {
            switch self {
            case .unknownProject(let id): return "No project with id \(id.uuidString)"
            case .unknownThread(let id):  return "No thread with id \(id)"
            }
        }
    }

    /// Send a prompt to a thread in any project. The send runs through the
    /// normal `sendPrompt` pipeline via a synthetic `WindowState`, so all the
    /// usual side-effects (title generation, briefing updates, persistence)
    /// still fire and any UI windows currently bound to the same session see
    /// the assistant tokens live via the shared `sessionStates` dictionary.
    func sendCrossProject(
        projectId: UUID?,
        threadId: String?,
        prompt: String,
        agentProvider: AgentProvider? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        waitForResponse: Bool = true,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> CrossProjectSendResult {
        // Resolve target project + thread.
        let resolvedProject: Project
        let resolvedThreadId: String?

        if let threadId {
            guard let summary = allSessionSummaries.first(where: { $0.id == threadId })
                ?? threadStore.fetch(id: threadId).map({ $0.toSummary() })
            else {
                throw CrossProjectSendError.unknownThread(threadId)
            }
            guard let proj = projects.first(where: { $0.id == summary.projectId }) else {
                throw CrossProjectSendError.unknownProject(summary.projectId)
            }
            resolvedProject = proj
            resolvedThreadId = threadId
        } else if let projectId {
            guard let proj = projects.first(where: { $0.id == projectId }) else {
                throw CrossProjectSendError.unknownProject(projectId)
            }
            resolvedProject = proj
            resolvedThreadId = nil
        } else {
            throw CrossProjectSendError.unknownProject(UUID())
        }

        // Build a synthetic WindowState. AppState.sessionStates is shared across
        // windows, so the message + stream are visible to any real window that
        // happens to also be viewing this session.
        let window = WindowState()
        window.selectedProject = resolvedProject
        window.currentSessionId = resolvedThreadId

        // Carry over per-session overrides for a new thread; for an existing
        // thread we leave the session's own stored values alone (the resume
        // path in sendPrompt reads from `sessionStates[sessionKey]`).
        if resolvedThreadId == nil {
            if let agentProvider {
                window.sessionAgentProvider = agentProvider
            }
            if let model {
                window.sessionModel = model
            }
            if let effort {
                window.sessionEffort = effort
            }
            if let permissionMode {
                window.sessionPermissionMode = permissionMode
            }
        }

        guard let streamId = await sendPrompt(prompt, displayText: prompt, in: window) else {
            return CrossProjectSendResult(
                threadId: resolvedThreadId ?? "",
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: "Send failed: no session could be allocated."
            )
        }

        // After sendPrompt returns, window.currentSessionId is the (possibly
        // pending-) key the stream is bound to. The CLI may rename it to its
        // own sid mid-stream; we surface whichever id the completion lands on.
        let postSendThreadId = window.currentSessionId ?? resolvedThreadId ?? ""

        if !waitForResponse {
            // Don't leak the result in the dictionary — the caller is
            // fire-and-forget. Drop it once it lands.
            Task { [weak self] in
                _ = await self?.awaitStreamCompletion(streamId: streamId, timeout: timeoutSeconds)
            }
            return CrossProjectSendResult(
                threadId: postSendThreadId,
                projectId: resolvedProject.id,
                done: false,
                assistantText: "",
                error: nil
            )
        }

        let completion = await awaitStreamCompletion(streamId: streamId, timeout: timeoutSeconds)
        if let completion {
            return CrossProjectSendResult(
                threadId: completion.sessionId,
                projectId: resolvedProject.id,
                done: completion.error == nil,
                assistantText: completion.assistantText,
                error: completion.error
            )
        } else {
            // Timed out. Surface the partial assistant text we have so far so
            // the caller can decide whether to poll back via get_thread_messages.
            let partial = lastAssistantResponseText(in: stateForSession(window.currentSessionId ?? "").messages)
            return CrossProjectSendResult(
                threadId: window.currentSessionId ?? postSendThreadId,
                projectId: resolvedProject.id,
                done: false,
                assistantText: partial,
                error: nil
            )
        }
    }

    /// Drop "No response requested." text blocks from the assistant message
    /// at `idx`. If the message has no blocks left after the strip, remove
    /// it entirely. Called at turn-finalization sites — the marker is the
    /// model's response when a turn arrives without a user prompt
    /// (ScheduleWakeup, hook re-entry) and reads as noise in the chat UI.
    /// Strip CLI no-op meta text ("no response requested") from a message.
    ///
    /// `removeIfEmpty` controls whether a message left with no blocks is also
    /// deleted. The normal stream path passes `true` to discard pure no-op
    /// envelopes; the cancel path passes `false` so pausing a turn never makes
    /// the partial assistant bubble disappear.
    private static func stripNoOpText(at idx: Int, in messages: inout [ChatMessage], removeIfEmpty: Bool = true) {
        guard messages.indices.contains(idx) else { return }
        messages[idx].blocks.removeAll { block in
            guard let text = block.text else { return false }
            return CLIMetaEnvelope.isNoResponseRequested(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if removeIfEmpty, messages[idx].blocks.isEmpty {
            messages.remove(at: idx)
        }
    }

    /// Wrap a branch briefing into a system-prompt section the agent can use as
    /// background context. The briefing is auto-generated from earlier threads,
    /// so it is framed as advisory rather than authoritative.
    private static func branchBriefingSystemPrompt(branch: String, briefing: String) -> String {
        let trimmed = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        # Current branch briefing

        The notes below are an accumulated briefing of recent work on this \
        project's current branch (`\(branch)`). They are auto-generated from \
        previous chat threads — treat them as background context for the user's \
        request, and be aware they may be incomplete or slightly out of date.

        \(trimmed)
        """
    }

    private func processStream(
        streamId: UUID,
        prompt: String,
        cwd: String,
        cliSessionId: String?,
        internalSessionKey: String,
        agentProvider: AgentProvider,
        model: String?,
        effort: String? = nil,
        hookSettingsPath: String?,
        permissionMode: PermissionMode = .default,
        hookSessionMode: PermissionMode? = nil,
        projectId: UUID,
        window: WindowState
    ) async {
        // Mode used when registering a session with PermissionServer for hook auto-approve.
        // When plan toggle is on, `permissionMode` is `.plan` (for the CLI flag) but the
        // user's dropdown choice (e.g. `.auto`) should still drive the hook policy.
        let registerMode = hookSessionMode ?? permissionMode
        let streamStart = Date()
        logger.info("[Stream:UI] starting processStream (cli=\(cliSessionId ?? "new"), key=\(internalSessionKey))")

        var sessionKey = internalSessionKey

        // Resolve per-backend send-request fields (MCP injection, ACP client
        // spec, model split) before dispatching through the unified protocol.
        var mcpClaudeConfigPath: String? = nil
        var extraSystemPrompt: String? = nil
        var mcpCodexOverrides: [String] = []
        var acpMCPServers: [JSONValue] = []
        var acpSpec: ACPClientSpec? = nil
        var resolvedPrompt = prompt
        var resolvedModel: String? = model
        var resolvedSendMode: PermissionMode = permissionMode
        var earlyStream: AsyncStream<StreamEvent>? = nil

        func appendExtraSystemPrompt(_ context: String) {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let existing = extraSystemPrompt, !existing.isEmpty {
                extraSystemPrompt = "\(existing)\n\n\(trimmed)"
            } else {
                extraSystemPrompt = trimmed
            }
        }

        switch agentProvider {
        case .claudeCode:
            // Allocate a per-session IDE-MCP port so the Claude agent can call
            // IDE-only tools — cross-project chat (`ide__send_to_thread`),
            // thread history, running jobs, usage. The bridge is a perl
            // one-liner Claude runs as the `rxcode-ide` MCP server child.
            let idePort = await ideMCPServer.allocate(
                sessionKey: sessionKey,
                capabilities: AgentProvider.claudeCode.staticCapabilities
            )
            let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
            mcpClaudeConfigPath = await mcp.writeClaudeConfig(projectPath: cwd, bridgeCommand: bridge)
            // Surface the accumulated briefing for the project's current branch
            // to the agent as background context via `--append-system-prompt`.
            if let branch = await GitHelper.currentBranch(at: cwd),
               let briefing = threadStore.branchBriefingItem(projectId: projectId, branch: branch) {
                extraSystemPrompt = Self.branchBriefingSystemPrompt(
                    branch: branch,
                    briefing: briefing.briefing
                )
            }
            if let skillContext = await marketplace.promptContext(for: .claudeCode) {
                appendExtraSystemPrompt(skillContext)
            }
        case .codex:
            mcpCodexOverrides = await mcp.codexConfigOverrides(projectPath: cwd)
            mcpCodexOverrides += await marketplace.codexConfigOverrides()
            if let skillContext = await marketplace.promptContext(for: .codex) {
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(prompt)"
            }
            resolvedSendMode = registerMode
        case .acp:
            // Allocate a per-session IDE-MCP port so the ACP agent can call
            // polyfill / introspection tools. The agent's MCP child is a
            // perl one-liner that bridges its stdio to our TCP listener;
            // the listener stays bound to this session for its lifetime.
            let idePort = await ideMCPServer.allocate(
                sessionKey: sessionKey,
                capabilities: AgentProvider.acp.staticCapabilities
            )
            let bridge = idePort.map { IDEMCPServer.bridgeCommand(forPort: $0) }
            acpMCPServers = await mcp.acpMCPServers(
                projectPath: cwd,
                bridgeCommand: bridge
            )
            if let skillContext = await marketplace.promptContext(for: .acp) {
                resolvedPrompt = "\(skillContext)\n\nUser request:\n\(prompt)"
            }
            // `model` may be a composite `<clientId>::<model>` key (from the picker)
            // or a bare model id (from a per-session override).
            let split = acpSelectionParts(for: model)
            let resolvedClientId = split?.clientId
                ?? sessionStates[sessionKey]?.acpClientId
                ?? selectedACPClientId
            resolvedModel = split?.model ?? model
            resolvedSendMode = registerMode
            if let spec = acpClients.first(where: { $0.id == resolvedClientId && $0.enabled }) {
                acpSpec = spec
            } else {
                logger.error("[ACP] no enabled client for id=\(resolvedClientId, privacy: .public)")
                earlyStream = AsyncStream<StreamEvent> { c in
                    c.yield(.user(UserMessage(
                        toolUseId: nil,
                        content: "No ACP client configured. Add one in Settings → ACP Clients.",
                        isError: true
                    )))
                    c.yield(.result(ResultEvent(
                        durationMs: nil, totalCostUsd: nil,
                        sessionId: cliSessionId ?? sessionKey,
                        isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                    )))
                    c.finish()
                }
            }
        }

        let stream: AsyncStream<StreamEvent>
        if let earlyStream {
            stream = earlyStream
        } else {
            let request = BackendSendRequest(
                streamId: streamId,
                prompt: resolvedPrompt,
                cwd: cwd,
                sessionId: cliSessionId,
                model: resolvedModel,
                effort: effort,
                permissionMode: resolvedSendMode,
                planMode: permissionMode == .plan,
                hookSettingsPath: hookSettingsPath,
                mcpClaudeConfigPath: mcpClaudeConfigPath,
                extraSystemPrompt: extraSystemPrompt,
                mcpCodexOverrides: mcpCodexOverrides,
                acpMCPServers: acpMCPServers,
                acpSpec: acpSpec,
                clientSessionKey: sessionKey
            )
            stream = await backend(for: agentProvider).send(request)
        }

        startFlushTimer(for: sessionKey)

        var eventCount = 0
        var lastEventTime = Date()

        do {
            for await event in stream {
                eventCount += 1
                let gap = Date().timeIntervalSince(lastEventTime)
                lastEventTime = Date()

                guard !Task.isCancelled else {
                    logger.info("[Stream:UI] task cancelled after \(eventCount) events")
                    break
                }

                let ownsSession = stateForSession(sessionKey).activeStreamId == streamId

                if !ownsSession {
                    if case .result(let resultEvent) = event {
                        logger.info("[Stream:UI] event #\(eventCount) .result received after losing ownership — saving to disk")
                        await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)
                        if sessionKey != resultEvent.sessionId {
                            if let state = sessionStates.removeValue(forKey: sessionKey) {
                                sessionStates[resultEvent.sessionId] = state
                            }
                            sessionIdRedirect[sessionKey] = resultEvent.sessionId
                            sessionKey = resultEvent.sessionId
                        }
                        let msgs = stateForSession(sessionKey).messages
                        if !msgs.isEmpty {
                            await saveSession(sessionId: resultEvent.sessionId, projectId: projectId, messages: msgs)
                        }
                    } else {
                        logger.debug("[Stream:UI] event #\(eventCount) — stream \(streamId) no longer owns session \(sessionKey), skipping")
                    }
                    continue
                }

                switch event {
                case .system(let systemEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .system (gap=\(String(format: "%.1f", gap))s)")
                    if let model = systemEvent.model {
                        updateState(sessionKey) { $0.activeModelName = model }
                    }
                    // Hook events (SessionStart, PreToolUse, etc.) carry the parent's session_id,
                    // not this subprocess's. Acting on them flips currentSessionId mid-stream and
                    // triggers MessageListView's fade-out/in — visible as a blink.
                    let isHookEvent = systemEvent.subtype.hasPrefix("hook_")
                    if let sid = systemEvent.sessionId, !isHookEvent {
                        await permission.registerSession(sid: sid, projectKey: cwd, mode: registerMode)
                        // Capture the sessionKey BEFORE the reassignment so the
                        // reconciler can rename the previous row in place when
                        // the CLI advances `session_id` mid-stream.
                        let previousSessionKey = sessionKey
                        if sessionKey != sid {
                            if let state = sessionStates.removeValue(forKey: previousSessionKey) {
                                sessionStates[sid] = state
                            }
                            renameDraftState(from: previousSessionKey, to: sid, in: window)
                            sessionIdRedirect[previousSessionKey] = sid
                            sessionKey = sid
                            startFlushTimer(for: sid)

                            // If this is the foreground session, also update window.currentSessionId.
                            // Do NOT treat `currentSessionId == nil` (the new-thread page) as foreground
                            // for an arbitrary streaming session — that caused the UI to auto-navigate
                            // to a previously-detached thread whenever its CLI advanced its session_id
                            // (e.g. pending→real on first system event, or compact_boundary swap).
                            let isFg = (window.currentSessionId ?? window.newSessionKey) == previousSessionKey
                            if isFg { window.currentSessionId = sid }
                        }

                        let expectedPlaceholder = "pending-\(streamId.uuidString)"
                        if window.pendingPlaceholderIds.contains(expectedPlaceholder),
                           let idx = allSessionSummaries.firstIndex(where: { $0.id == expectedPlaceholder })
                        {
                            let old = allSessionSummaries[idx]
                            // Preserve the placeholder's original timestamp so an empty
                            // session (no assistant content yet) doesn't leapfrog
                            // genuinely-recent chats with an "in 0s" updatedAt. The
                            // first save once content arrives will refresh updatedAt.
                            let replacement = ChatSession(
                                id: sid,
                                projectId: old.projectId,
                                title: old.title,
                                messages: [],
                                createdAt: old.createdAt,
                                updatedAt: old.createdAt,
                                isPinned: old.isPinned,
                                agentProvider: old.agentProvider,
                                model: old.model,
                                effort: old.effort,
                                permissionMode: old.permissionMode,
                                origin: old.origin,
                                worktreePath: old.worktreePath,
                                worktreeBranch: old.worktreeBranch,
                                isArchived: old.isArchived,
                                archivedAt: old.archivedAt
                            )
                            allSessionSummaries.removeAll { $0.id == expectedPlaceholder || $0.id == sid }
                            allSessionSummaries.insert(replacement.summary, at: 0)
                            threadStore.renameId(from: expectedPlaceholder, to: sid)
                            threadStore.upsert(replacement.summary, cliSessionId: sid)
                            window.removePendingPlaceholder(expectedPlaceholder)
                        } else {
                            if window.pendingPlaceholderIds.contains(expectedPlaceholder) {
                                window.removePendingPlaceholder(expectedPlaceholder)
                                allSessionSummaries.removeAll { $0.id == expectedPlaceholder }
                                threadStore.delete(id: expectedPlaceholder)
                            }

                            // A retry reuses the same pending session key (oldKey) with a new streamId,
                            // so expectedPlaceholder won't match oldKey. Clean up the stale placeholder
                            // here to prevent the old entry from persisting as a duplicate in history.
                            let oldKey = sessionKey == sid ? internalSessionKey : sessionKey
                            if oldKey != expectedPlaceholder, window.pendingPlaceholderIds.contains(oldKey) {
                                allSessionSummaries.removeAll { $0.id == oldKey }
                                threadStore.delete(id: oldKey)
                                window.removePendingPlaceholder(oldKey)
                            }

                            // Decide whether to rename the previous row, insert a fresh
                            // one, or do nothing. Renaming in place is the load-bearing
                            // case: it stops empty "New Session" rows from accumulating
                            // every time the CLI advances `session_id` mid-stream (e.g.
                            // after a `compact_boundary`).
                            if let project = projects.first(where: { $0.id == projectId }) {
                                let msgs = stateForSession(sessionKey).messages
                                let firstUser = msgs.first(where: { $0.role == .user })
                                let action = SessionRowReconciler.decide(
                                    newSid: sid,
                                    previousKey: previousSessionKey,
                                    existingIds: Set(allSessionSummaries.map { $0.id }),
                                    firstUserMessageContent: firstUser?.content
                                )
                                switch action {
                                case .noop:
                                    break
                                case .renameInPlace(let from, let to):
                                    if let idx = allSessionSummaries.firstIndex(where: { $0.id == from }) {
                                        let old = allSessionSummaries[idx]
                                        let renamed = ChatSession.Summary(
                                            id: to,
                                            projectId: old.projectId,
                                            title: old.title,
                                            createdAt: old.createdAt,
                                            updatedAt: old.updatedAt,
                                            isPinned: old.isPinned,
                                            agentProvider: old.agentProvider,
                                            model: old.model,
                                            effort: old.effort,
                                            permissionMode: old.permissionMode,
                                            origin: old.origin,
                                            worktreePath: old.worktreePath,
                                            worktreeBranch: old.worktreeBranch,
                                            isArchived: old.isArchived,
                                            archivedAt: old.archivedAt
                                        )
                                        allSessionSummaries.remove(at: idx)
                                        allSessionSummaries.removeAll { $0.id == to }
                                        allSessionSummaries.insert(renamed, at: 0)
                                        threadStore.renameId(from: from, to: to)
                                        threadStore.upsert(renamed, cliSessionId: to)
                                    }
                                case .insertNew(let id, let title):
                                    // Use the user-message timestamp so the row doesn't
                                    // reorder above more recent chats while still empty.
                                    let firstUserDate = firstUser?.timestamp ?? Date()
                                    let inserted = ChatSession.Summary(
                                        id: id,
                                        projectId: project.id,
                                        title: title,
                                        createdAt: firstUserDate,
                                        updatedAt: firstUserDate,
                                        isPinned: false,
                                        agentProvider: agentProvider,
                                        origin: agentProvider.defaultSessionOrigin
                                    )
                                    allSessionSummaries.insert(inserted, at: 0)
                                    threadStore.upsert(inserted, cliSessionId: id)
                                }
                            }
                        }
                        if previousSessionKey != sid {
                            broadcastMobileSessionRedirect(from: previousSessionKey, to: sid)
                        }
                    }

                    if systemEvent.subtype == "compact_boundary" {
                        updateState(sessionKey) { state in
                            state.messages.append(ChatMessage(role: .assistant, content: "Previous conversation has been compacted", isCompactBoundary: true))
                        }
                    }

                case .assistant(let assistantMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .assistant (gap=\(String(format: "%.1f", gap))s, blocks=\(assistantMessage.content.count))")
                    if assistantMessage.content.contains(where: {
                        if case .thinking = $0 { return true }
                        return false
                    }) {
                        updateState(sessionKey) { $0.isThinking = true }
                    }
                    // A turn can contain several model invocations (one per tool round-trip);
                    // each emits its own `usage.output_tokens` starting from zero. Track the
                    // running max per message id and sum across ids to get the turn total.
                    if let liveOutput = assistantMessage.usage?.outputTokens {
                        updateState(sessionKey) { state in
                            if let messageId = assistantMessage.id {
                                let existing = state.currentTurnOutputTokensByMessage[messageId] ?? 0
                                state.currentTurnOutputTokensByMessage[messageId] = max(existing, liveOutput)
                            } else {
                                state.currentTurnOutputTokensUnkeyed = max(state.currentTurnOutputTokensUnkeyed, liveOutput)
                            }
                        }
                        if agentProvider == .codex {
                            let total = stateForSession(sessionKey).currentTurnOutputTokens
                            logger.info("[Stream:UI] Codex usage applied messageId=\(assistantMessage.id ?? "<nil>", privacy: .public) output=\(liveOutput) total=\(total)")
                        }
                    }
                    // ACP-style providers deliver fully-formed tool_use blocks inside .assistant
                    // events (no content_block_start raw stream). Commit any buffered text first
                    // so tool bubbles appear after — and not in the middle of — the prior text.
                    let hasToolUse = assistantMessage.content.contains {
                        if case .toolUse = $0 { return true }
                        return false
                    }
                    if hasToolUse {
                        flushPendingUpdates(for: sessionKey)
                    }

                    updateState(sessionKey) { state in
                        // Text fallback: only buffer text when no text_delta has been received in
                        // this turn. Normally content_block_delta(text_delta) is the primary path.
                        let canBufferText: Bool = {
                            guard state.textDeltaBuffer.isEmpty else { return false }
                            let afterLastUser = (state.messages.lastIndex(where: { $0.role == .user }).map { $0 + 1 }) ?? 0
                            return !state.messages.suffix(from: afterLastUser).contains {
                                $0.role == .assistant && $0.blocks.contains(where: \.isText)
                            }
                        }()

                        for block in assistantMessage.content {
                            switch block {
                            case .text(let text):
                                if canBufferText, !text.isEmpty {
                                    state.textDeltaBuffer += text
                                }
                            case .toolUse(let id, let name, let input):
                                state.isThinking = false
                                // Merge updates by id: ACP agents may re-emit the same toolUse
                                // with additional input (e.g. diff content arriving via a
                                // follow-up tool_call_update). Patch the existing block in
                                // place so the live edit info reaches `flushPendingUpdates`
                                // when the result lands.
                                if let existingMsgIdx = state.messages.indices.reversed().first(where: {
                                    state.messages[$0].toolCallIndex(id: id) != nil
                                }),
                                   let existingBlockIdx = state.messages[existingMsgIdx].toolCallIndex(id: id) {
                                    var merged = state.messages[existingMsgIdx].blocks[existingBlockIdx].toolCall?.input ?? [:]
                                    for (key, value) in input { merged[key] = value }
                                    state.messages[existingMsgIdx].blocks[existingBlockIdx].toolCall?.input = merged
                                } else {
                                    if state.needsNewMessage {
                                        if let idx = state.messages.indices.reversed().first(where: {
                                            state.messages[$0].role == .assistant && state.messages[$0].isStreaming
                                        }) {
                                            state.messages[idx].isStreaming = false
                                            state.messages[idx].finalizeToolCalls()
                                            Self.stripNoOpText(at: idx, in: &state.messages)
                                        }
                                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                                        state.needsNewMessage = false
                                    } else if state.messages.last?.role != .assistant
                                                || !(state.messages.last?.isStreaming ?? false) {
                                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                                    }
                                    if let lastIndex = state.messages.indices.last,
                                       state.messages[lastIndex].role == .assistant {
                                        state.messages[lastIndex].appendToolCall(ToolCall(id: id, name: name, input: input))
                                    }
                                }
                            case .thinking:
                                state.isThinking = true
                            }
                        }
                    }

                case .user(let userMessage):
                    logger.debug("[Stream:UI] event #\(eventCount) .user (gap=\(String(format: "%.1f", gap))s, toolUseId=\(userMessage.toolUseId ?? "none"))")
                    updateState(sessionKey) { state in
                        guard let toolUseId = userMessage.toolUseId else { return }
                        state.pendingToolResults.append((toolUseId, userMessage.content, userMessage.isError))
                        state.needsNewMessage = true
                    }

                case .result(let resultEvent):
                    logger.info("[Stream:UI] event #\(eventCount) .result (gap=\(String(format: "%.1f", gap))s, isError=\(resultEvent.isError), session=\(resultEvent.sessionId))")

                    // With `--input-format stream-json` the CLI stays alive waiting for more
                    // input. Close stdin on `result` so it exits cleanly, then finalize so
                    // any subagent children that survived the parent CLI get reaped.
                    await finalizeAgentStream(agentProvider: agentProvider, streamId: streamId)

                    if sessionKey != resultEvent.sessionId {
                        if let state = sessionStates.removeValue(forKey: sessionKey) {
                            sessionStates[resultEvent.sessionId] = state
                        }
                        sessionKey = resultEvent.sessionId
                    }

                    // A background completion is "finished, unread". Setting the
                    // flag inside finalizeStreamSession means the trailing
                    // `.streamingFinished` broadcast already carries it to mobile.
                    let isFg = (window.currentSessionId ?? window.newSessionKey) == sessionKey
                    let markUnread = !isFg && !resultEvent.isError

                    finalizeStreamSession(for: sessionKey) { state in
                        if let cost = resultEvent.totalCostUsd { state.costUsd = cost }
                        if let duration = resultEvent.durationMs { state.durationMs += duration }
                        if let turns = resultEvent.totalTurns { state.turns += turns }
                        if let usage = resultEvent.usage {
                            state.inputTokens += usage.inputTokens
                            state.outputTokens += usage.outputTokens
                            state.cacheCreationTokens += usage.cacheCreationInputTokens
                            state.cacheReadTokens += usage.cacheReadInputTokens
                        }
                        if markUnread { state.hasUncheckedCompletion = true }
                    }

                    recordStreamCompletion(
                        streamId: streamId,
                        sessionId: resultEvent.sessionId,
                        assistantText: lastAssistantResponseText(in: stateForSession(sessionKey).messages),
                        error: resultEvent.isError ? "Agent reported an error result." : nil
                    )

                    if isFg {
                        window.currentSessionId = resultEvent.sessionId
                        if resultEvent.isError {
                            let errText = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)
                                ?? "\(agentProvider.displayName) returned an error."
                            addErrorMessage(errText, in: window)
                        }
                    }

                    await saveSession(
                        sessionId: resultEvent.sessionId,
                        projectId: projectId,
                        messages: stateForSession(sessionKey).messages
                    )

                    if agentProvider == .claudeCode {
                        reconcileFromDisk(sessionId: resultEvent.sessionId, projectId: projectId, cwd: cwd)
                    }

                    if !resultEvent.isError {
                        let sid = resultEvent.sessionId
                        let key = sessionKey
                        let cwdCapture = cwd
                        if agentProvider == .claudeCode {
                            Task { [weak self] in
                                guard let self else { return }
                                if let pct = await claude.fetchContextPercentage(sessionId: sid, cwd: cwdCapture) {
                                    updateState(key) { $0.lastTurnContextUsedPercentage = pct }
                                }
                            }
                        }

                        if notificationsEnabled {
                            let summary = allSessionSummaries.first(where: { $0.id == resultEvent.sessionId })
                            let title = summary?.title ?? "New Session"
                            let responseText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)
                            let fallbackBody = responseNotificationFallback(from: responseText)
                            let pid = projectId
                            let sid = resultEvent.sessionId
                            let postLocalBanner = !NSApp.isActive
                            Task { [weak self] in
                                var body = fallbackBody
                                if let self, let summary {
                                    body = await self.generateResponseNotificationSummary(responseText: responseText, summary: summary) ?? fallbackBody
                                }
                                await NotificationService.shared.postResponseComplete(title: title, body: body, projectId: pid, sessionId: sid, postLocalBanner: postLocalBanner)
                            }
                        }

                        scheduleThreadSummaryUpdate(
                            sessionId: resultEvent.sessionId,
                            projectId: projectId,
                            cwd: cwd,
                            messages: stateForSession(sessionKey).messages
                        )

                        // If this session is running in the background, automatically process any queued messages.
                        // Foreground sessions are handled by InputBarView via isStreaming onChange.
                        if !isFg {
                            await processBackgroundQueue(for: sessionKey, projectId: projectId, cwd: cwd, in: window)
                        }
                    }

                case .rateLimitEvent(let info):
                    logger.warning("[Stream:UI] event #\(eventCount) .rateLimitEvent (retrySec=\(info.retrySec ?? 0))")
                    if (window.currentSessionId ?? window.newSessionKey) == sessionKey,
                       let retry = info.retrySec, retry > 0
                    {
                        addErrorMessage("Rate limited. Retrying in \(Int(retry))s...", in: window)
                    }

                case .todoSnapshot(let snapshot):
                    let targetSession = snapshot.sessionId ?? sessionKey
                    let done = snapshot.items.filter { $0.status == .completed }.count
                    let active = snapshot.items.first(where: { $0.status == .inProgress })?.activeForm ?? "-"
                    logger.info(
                        "[TodoSnapshot] session=\(targetSession, privacy: .public) total=\(snapshot.items.count) done=\(done) active=\(active, privacy: .public)"
                    )
                    threadStore.upsertTodoSnapshot(sessionId: targetSession, items: snapshot.items)
                    broadcastMobileSessionStatus(sessionID: targetSession)

                case .acpModelsDiscovered(let event):
                    logger.info("[Stream:UI] event #\(eventCount) .acpModelsDiscovered clientId=\(event.clientId, privacy: .public) configId=\(event.config.configId, privacy: .public) models=\(event.config.options.count) [\(Self.acpModelListDescription(event.config.options), privacy: .public)]")
                    applyDiscoveredACPModels(clientId: event.clientId, config: event.config)

                case .unknown(let raw):
                    if eventCount <= 5 || eventCount % 100 == 0 {
                        logger.debug("[Stream:UI] event #\(eventCount) .unknown (gap=\(String(format: "%.1f", gap))s, len=\(raw.count))")
                    }
                    handlePartialEvent(raw, for: sessionKey)
                }
            }

            let elapsed = Date().timeIntervalSince(streamStart)
            logger.info("[Stream:UI] stream ended after \(eventCount) events, \(String(format: "%.1f", elapsed))s total")

            // Consume any remaining stderr — used as error message content below.
            // If already consumed at result.isError time, this returns nil.
            let stderrOutput = await consumeAgentStderr(agentProvider: agentProvider, streamId: streamId)

            if eventCount == 0 {
                // User cancellation revokes activeStreamId or cancels the task — distinguish
                // that from a real "CLI died with no output" failure.
                let wasCancelled = Task.isCancelled || stateForSession(sessionKey).activeStreamId != streamId
                if !wasCancelled {
                    let errorMsg = stderrOutput ?? "No response received"
                    addErrorMessage(errorMsg, in: window)
                    logger.error("[Stream:UI] no events received — appending error bubble. stderr=\(stderrOutput ?? "nil")")
                } else {
                    logger.debug("[Stream:UI] no events received — suppressed (cancelled). stderr=\(stderrOutput ?? "nil")")
                }
            }

            let isStillOwner = stateForSession(sessionKey).activeStreamId == streamId
            let stillStreaming = stateForSession(sessionKey).isStreaming
            if stillStreaming, isStillOwner {
                logger.warning("[Stream:UI] isStreaming was still true at stream end — forcing cleanup")
                let markUnread = (window.currentSessionId ?? window.newSessionKey) != sessionKey
                finalizeStreamSession(for: sessionKey) { state in
                    if markUnread { state.hasUncheckedCompletion = true }
                }

                // If the last assistant message is invisible after cleanup (blocks=[] because
                // all tool calls had empty/nil results), show an error bubble so the user
                // understands what happened rather than seeing no response at all.
                let lastMsg = stateForSession(sessionKey).messages.last
                if lastMsg.map({ $0.role == .assistant && $0.blocks.isEmpty }) == true {
                    let errorMsg = stderrOutput ?? "Response was interrupted"
                    updateState(sessionKey) { state in
                        state.messages.append(ChatMessage(role: .assistant, content: errorMsg, isError: true))
                    }
                }

                let msgs = stateForSession(sessionKey).messages
                if !msgs.isEmpty {
                    await saveSession(sessionId: sessionKey, projectId: projectId, messages: msgs)
                }
            } else if stillStreaming, !isStillOwner {
                let currentOwner = stateForSession(sessionKey).activeStreamId
                if currentOwner == nil {
                    logger.warning("[Stream:UI] stream \(streamId) ended — no active owner for session, forcing cleanup")
                    finalizeStreamSession(for: sessionKey)
                    let msgs = stateForSession(sessionKey).messages
                    if !msgs.isEmpty {
                        await saveSession(sessionId: sessionKey, projectId: projectId, messages: msgs)
                    }
                } else {
                    logger.info("[Stream:UI] stream \(streamId) ended but newer stream \(currentOwner!) owns session — skipping cleanup")
                }
            }

            // Fallback completion record: covers cancellations, no-events errors,
            // and any path where `.result` was not received. The `.result` case
            // already records a completion before reaching here — recordStreamCompletion
            // is idempotent (it overwrites with the latest), but if a prior call set a
            // successful completion we don't want to clobber it with an error.
            if pendingStreamCompletions[streamId] == nil {
                let assistantText = lastAssistantResponseText(in: stateForSession(sessionKey).messages)
                let errorMsg: String? = eventCount == 0
                    ? (stderrOutput ?? "Stream ended with no events.")
                    : (Task.isCancelled ? "Stream was cancelled." : nil)
                recordStreamCompletion(
                    streamId: streamId,
                    sessionId: sessionKey,
                    assistantText: assistantText,
                    error: errorMsg
                )
            }
        }
    }

    private func finalizeAgentStream(agentProvider: AgentProvider, streamId: UUID) async {
        // Claude needs an explicit stdin close before finalize so the CLI
        // sees EOF; other backends manage stdin internally.
        if agentProvider == .claudeCode {
            await claude.closeStdin(streamId: streamId)
        }
        await backend(for: agentProvider).finalize(streamId: streamId)
    }

    /// Release the per-session IDE-MCP listener allocated for ACP turns.
    /// Safe to call for non-ACP providers (no-op).
    private func releaseIDESession(sessionKey: String) async {
        await ideMCPServer.release(sessionKey: sessionKey)
    }

    private func consumeAgentStderr(agentProvider: AgentProvider, streamId: UUID) async -> String? {
        switch agentProvider {
        case .claudeCode:
            return await claude.consumeStderr(for: streamId)
        case .codex:
            return await codex.consumeStderr(for: streamId)
        case .acp:
            return await acp.consumeStderr(for: streamId)
        }
    }

    // MARK: - Text Delta Throttle (50ms)

    private func startFlushTimer(for sessionKey: String) {
        stopFlushTimer(for: sessionKey)
        let capturedKey = sessionKey
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                self?.flushPendingUpdates(for: capturedKey)
            }
        }
        sessionStates[sessionKey, default: SessionStreamState()].flushTask = task
    }

    private func stopFlushTimer(for sessionKey: String) {
        sessionStates[sessionKey]?.flushTask?.cancel()
        sessionStates[sessionKey]?.flushTask = nil
    }

    private func flushPendingUpdates(for key: String) {
        guard var state = sessionStates[key] else { return }

        let hasText = !state.textDeltaBuffer.isEmpty
        let hasToolResults = !state.pendingToolResults.isEmpty

        guard hasText || hasToolResults else { return }

        let prevMessages = state.messages

        func lastAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant }
        }
        func lastStreamingAssistantIdx() -> Int? {
            state.messages.indices.reversed().first { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }
        }

        // 1. Tool results — apply to the current streaming assistant message
        if hasToolResults {
            let results = state.pendingToolResults
            state.pendingToolResults.removeAll(keepingCapacity: true)
            if let idx = lastAssistantIdx() {
                for (toolUseId, content, isError) in results {
                    let editPersistInfos: [(path: String, hunks: [PreviewFile.EditHunk], isWrite: Bool)] = {
                        guard !isError,
                              let blockIdx = state.messages[idx].toolCallIndex(id: toolUseId),
                              let call = state.messages[idx].blocks[blockIdx].toolCall,
                              ["edit", "multiedit", "multi_edit", "write"].contains(call.name.lowercased())
                        else { return [] }
                        let claudeHunks = call.fileEditHunks
                        if !claudeHunks.isEmpty, let path = call.editedFilePath {
                            return [(path, claudeHunks, call.name.lowercased() == "write")]
                        }
                        // Codex `fileChange` shape: one tool call may touch multiple files.
                        let codexDiffs = call.fileChangeDiffs
                        guard !codexDiffs.isEmpty else { return [] }
                        return codexDiffs.map { ($0.path, [$0.hunk], false) }
                    }()
                    // Preserve the user-decision summary on ExitPlanMode. After the user
                    // accepts/rejects the plan, the CLI emits its own follow-up tool_result
                    // ("User has approved your plan…") which would overwrite "Accepted with …"
                    // and flip the plan card back to "pending" — re-showing the accept buttons
                    // on a card that was just decided.
                    let skipResultOverwrite: Bool = {
                        guard let blockIdx = state.messages[idx].toolCallIndex(id: toolUseId),
                              let call = state.messages[idx].blocks[blockIdx].toolCall,
                              Self.isExitPlanModeCall(call),
                              let existing = call.result else { return false }
                        return Self.planDecisionResultPrefixes.contains { existing.hasPrefix($0) }
                    }()
                    if !skipResultOverwrite {
                        state.messages[idx].setToolResult(id: toolUseId, result: content, isError: isError)
                    }
                    if !editPersistInfos.isEmpty {
                        for info in editPersistInfos {
                            threadStore.appendFileEdit(
                                sessionId: key,
                                path: info.path,
                                hunks: info.hunks,
                                containsWrite: info.isWrite
                            )
                        }
                        threadFileEditsRevision &+= 1
                    }
                }
            }
        }

        // 2. Text delta flush
        if hasText {
            let buffered = state.textDeltaBuffer
            state.textDeltaBuffer = ""
            if let idx = lastStreamingAssistantIdx() {
                if state.needsNewMessage {
                    // New Claude turn after receiving tool result — start a new ChatMessage
                    state.messages[idx].isStreaming = false
                    state.messages[idx].finalizeToolCalls()
                    Self.stripNoOpText(at: idx, in: &state.messages)
                    state.needsNewMessage = false
                    state.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
                } else {
                    state.messages[idx].appendText(buffered)
                }
            } else {
                state.messages.append(ChatMessage(role: .assistant, content: buffered, isStreaming: true))
            }
        }

        sessionStates[key] = state
        broadcastMobileMessageDiff(sessionKey: key, prev: prevMessages, next: state.messages, isStreaming: state.isStreaming)
    }

    // MARK: - Stream Event Handler

    private func handlePartialEvent(_ raw: String, for sessionKey: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let event: [String: Any]
        if let type = json["type"] as? String, type == "stream_event",
           let nested = json["event"] as? [String: Any]
        {
            event = nested
        } else {
            event = json
        }

        guard let eventType = event["type"] as? String else { return }

        switch eventType {
        case "content_block_start":
            guard let contentBlock = event["content_block"] as? [String: Any],
                  let blockType = contentBlock["type"] as? String else { return }

            if blockType == "tool_use" {
                guard let id = contentBlock["id"] as? String,
                      let name = contentBlock["name"] as? String else { return }
                let toolCall = ToolCall(id: id, name: name, input: [:])
                // Flush the text buffer first so text blocks are committed before tools
                flushPendingUpdates(for: sessionKey)
                updateState(sessionKey) { state in
                    state.isThinking = false
                    // needsNewMessage: new Claude turn after tool result — create a new ChatMessage
                    if state.needsNewMessage {
                        if let idx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }) {
                            state.messages[idx].isStreaming = false
                            state.messages[idx].finalizeToolCalls()
                            Self.stripNoOpText(at: idx, in: &state.messages)
                        }
                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                        state.needsNewMessage = false
                    } else if state.messages.last?.role != .assistant || !(state.messages.last?.isStreaming ?? false) {
                        state.messages.append(ChatMessage(role: .assistant, isStreaming: true))
                    }
                    if let lastIndex = state.messages.indices.last,
                       state.messages[lastIndex].role == .assistant
                    {
                        state.messages[lastIndex].appendToolCall(toolCall)
                    }
                    // Ready to receive input_json_delta
                    state.activeToolId = id
                    state.activeToolInputBuffer = ""
                }
            } else if blockType == "text" {
                // New text block started — if needsNewMessage, prepare a new ChatMessage
                updateState(sessionKey) { state in
                    if state.needsNewMessage {
                        // Keep the flag so a new message is created on the next text_delta flush
                        // (needsNewMessage is handled inside flush)
                    }
                    state.isThinking = false
                    state.activeToolId = nil
                    state.activeToolInputBuffer = ""
                }
            } else if blockType == "thinking" {
                updateState(sessionKey) { $0.isThinking = true }
            }

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }

            if deltaType == "text_delta", let text = delta["text"] as? String {
                updateState(sessionKey) { state in
                    state.isThinking = false
                    state.textDeltaBuffer += text
                }
            } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                updateState(sessionKey) { state in
                    state.activeToolInputBuffer += partial
                }
            } else if deltaType == "thinking_delta" {
                updateState(sessionKey) { $0.isThinking = true }
            }

        case "content_block_stop":
            // Finalize tool_use input — parse the accumulated JSON and apply to the tool call
            updateState(sessionKey) { state in
                guard let toolId = state.activeToolId, !state.activeToolInputBuffer.isEmpty else {
                    state.activeToolId = nil
                    return
                }
                let buffer = state.activeToolInputBuffer
                state.activeToolId = nil
                state.activeToolInputBuffer = ""

                guard let inputData = buffer.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: inputData) else { return }

                if let msgIdx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant && state.messages[$0].isStreaming }),
                   let blockIdx = state.messages[msgIdx].toolCallIndex(id: toolId)
                {
                    state.messages[msgIdx].blocks[blockIdx].toolCall?.input = parsed
                    if let toolName = state.messages[msgIdx].blocks[blockIdx].toolCall?.name,
                       toolName.lowercased() == "todowrite"
                    {
                        let todos = TodoExtractor.parse(input: parsed)
                        let done = todos.filter { $0.status == .completed }.count
                        let active = todos.first(where: { $0.status == .inProgress })?.activeForm ?? "-"
                        logger.info(
                            "[TodoWrite] session=\(sessionKey, privacy: .public) total=\(todos.count) done=\(done) active=\(active, privacy: .public)"
                        )
                        threadStore.upsertTodoSnapshot(sessionId: sessionKey, items: todos)
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Cancel

    private func detachCurrentStream(in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        flushPendingUpdates(for: key)
        stopFlushTimer(for: key)
    }

    func cancelStreaming(in window: WindowState) async {
        let key = window.currentSessionId ?? window.newSessionKey
        let streamToCancel = sessionStates[key]?.activeStreamId
        sessionStates[key]?.streamTask?.cancel()
        sessionStates[key]?.streamTask = nil
        // Set isStreaming=false before suspending so that processStream — which may run
        // on the MainActor while we await — does not call finalizeStreamSession and
        // incorrectly mark the cancelled message as isResponseComplete=true.
        sessionStates[key]?.isStreaming = false
        sessionStates[key]?.activeStreamId = nil

        if let streamToCancel {
            let provider = sessionStates[key]?.agentProvider ?? effectiveModelSelection(in: window).provider
            await backend(for: provider).cancel(streamId: streamToCancel)
        }

        flushPendingUpdates(for: key)
        stopFlushTimer(for: key)

        updateState(key) { state in
            state.isStreaming = false
            state.isThinking = false
            state.needsNewMessage = false
            state.activeStreamId = nil
            state.streamTask = nil
            state.activeToolId = nil
            state.activeToolInputBuffer = ""
            state.textDeltaBuffer = ""
            state.pendingToolResults.removeAll()
            if let idx = state.messages.indices.reversed().first(where: {
                state.messages[$0].role == .assistant && state.messages[$0].isStreaming
            }) {
                // The user paused this turn — keep the partial assistant bubble
                // visible. markStreamInterrupted() retains in-progress tool calls
                // (flagged as interrupted) instead of dropping them, and the
                // no-op strip below is told not to delete an emptied message.
                state.messages[idx].markStreamInterrupted()
                if let start = state.streamingStartDate {
                    state.messages[idx].duration = Date().timeIntervalSince(start)
                }
                Self.stripNoOpText(at: idx, in: &state.messages, removeIfEmpty: false)
            }
            state.streamingStartDate = nil
            state.inFlightUserAttachments = []
        }

        window.showError = false
        window.errorMessage = nil

        // Save messages accumulated up to the point of cancellation to disk (prevent data loss).
        // The placeholder session (if any) is left in place so partial messages remain visible;
        // it will be promoted to the real CLI session id on the next user turn.
        if let project = window.selectedProject {
            let messages = stateForSession(key).messages
            if !messages.isEmpty {
                await saveSession(sessionId: key, projectId: project.id, messages: messages)
            }
        }
    }

    private func recordStreamingDuration(for key: String) {
        guard let start = sessionStates[key]?.streamingStartDate else { return }
        let duration = Date().timeIntervalSince(start)
        updateState(key) { state in
            state.streamingStartDate = nil
            if let idx = state.messages.indices.reversed().first(where: { state.messages[$0].role == .assistant }) {
                state.messages[idx].duration = duration
            }
        }
    }

    // MARK: - Permission Response

    func respondToPermission(_ request: PermissionRequest, decision: PermissionDecision, in window: WindowState) async {
        await permission.respond(toolUseId: request.id, decision: decision)
        window.pendingPermissions.removeAll { $0.id == request.id }
        mobilePendingRequests.removeValue(forKey: request.id)
        if let sessionId = request.sessionId {
            broadcastMobileSessionStatus(sessionID: sessionId)
        }
    }

    // MARK: - AskUserQuestion Response

    /// Deliver the user's answers for an AskUserQuestion tool call via the PreToolUse hook.
    ///
    /// AskUserQuestion is handled like any other PreToolUse hook: the PermissionServer is
    /// holding the HTTP connection open waiting for a decision. We resolve it with `allow` +
    /// `updatedInput: {questions, answers: {questionText: <answerValue>}}` so the CLI injects
    /// the answers into the tool input and proceeds.
    func respondToAskUserQuestion(
        toolUseId: String,
        answers: [Int: AskUserQuestion.Answer],
        in window: WindowState
    ) async {
        let key = window.currentSessionId ?? window.newSessionKey

        var updatedInput = JSONValue.object([
            "questions": .array([]),
            "answers": .object([:]),
        ])

        updateState(key) { state in
            for i in state.messages.indices.reversed() {
                guard let idx = state.messages[i].toolCallIndex(id: toolUseId),
                      let toolInput = state.messages[i].blocks[idx].toolCall?.input,
                      let parsed = AskUserQuestion(input: toolInput) else { continue }

                updatedInput = AskUserQuestion.updatedInputJSON(
                    originalInput: toolInput,
                    questions: parsed.questions,
                    answers: answers
                )
                let summary = AskUserQuestion.summary(questions: parsed.questions, answers: answers)
                state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                return
            }
        }

        window.pendingPermissions.removeAll { $0.id == toolUseId }
        let requestSessionId = mobilePendingRequests.removeValue(forKey: toolUseId)?.sessionId
        if window.presentedPermissionId == toolUseId {
            window.presentedPermissionId = nil
        }
        if let requestSessionId {
            broadcastMobileSessionStatus(sessionID: requestSessionId)
        }
        broadcastMobileQuestionQueue()

        await permission.respondAskUserQuestion(toolUseId: toolUseId, updatedInput: updatedInput)
    }

    /// User dismissed the question sheet without answering — resolve the hook as deny so
    /// the CLI does not block, and clear the pending entry from the window queue.
    func skipAskUserQuestion(toolUseId: String, in window: WindowState) async {
        window.pendingPermissions.removeAll { $0.id == toolUseId }
        let requestSessionId = mobilePendingRequests.removeValue(forKey: toolUseId)?.sessionId
        if window.presentedPermissionId == toolUseId {
            window.presentedPermissionId = nil
        }
        if let requestSessionId {
            broadcastMobileSessionStatus(sessionID: requestSessionId)
        }
        broadcastMobileQuestionQueue()
        await permission.respond(toolUseId: toolUseId, decision: .deny)
    }

    /// Apply a question answer that arrived from a paired mobile device.
    /// Resolves the CLI hook, mirrors the answer into chat history, and clears
    /// the request from every desktop window's queue. An empty `answers` array
    /// means the user chose "Skip All Questions" on mobile.
    private func handleMobileQuestionAnswer(_ payload: QuestionAnswerPayload) async {
        let toolUseId = payload.toolUseID
        guard let request = mobilePendingRequests[toolUseId] else { return }

        guard !payload.answers.isEmpty, let parsed = AskUserQuestion(input: request.toolInput) else {
            // Skip — or a malformed payload we cannot answer: deny the hook.
            clearPendingQuestion(toolUseId: toolUseId, sessionId: request.sessionId)
            await permission.respond(toolUseId: toolUseId, decision: .deny)
            return
        }

        var answers: [Int: AskUserQuestion.Answer] = [:]
        for entry in payload.answers {
            answers[entry.questionIndex] = entry.multiSelect
                ? .multi(entry.values)
                : .single(entry.values.first ?? "")
        }

        let updatedInput = AskUserQuestion.updatedInputJSON(
            originalInput: request.toolInput,
            questions: parsed.questions,
            answers: answers
        )
        let summary = AskUserQuestion.summary(questions: parsed.questions, answers: answers)

        if let sessionId = request.sessionId {
            updateState(sessionId) { state in
                for i in state.messages.indices.reversed() {
                    guard state.messages[i].toolCallIndex(id: toolUseId) != nil else { continue }
                    state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                    return
                }
            }
        }

        clearPendingQuestion(toolUseId: toolUseId, sessionId: request.sessionId)
        await permission.respondAskUserQuestion(toolUseId: toolUseId, updatedInput: updatedInput)
    }

    /// Apply a plan decision that arrived from a paired mobile device. Builds a
    /// transient `WindowState` bound to the target session — mirroring
    /// `handleMobileUserMessage` — and delegates to `respondToPlanDecision`,
    /// which owns all the desktop plan logic (CLI hook release, decision summary
    /// into `toolCall.result` + `planDecisionSummaries`, `threadStore` persist,
    /// one-shot plan-mode clear, follow-up permission mode, continuation prompt).
    /// The updated messages broadcast back through the normal session-update sync.
    private func handleMobilePlanDecision(_ payload: PlanDecisionPayload) async {
        let sessionID = resolveCurrentSessionId(payload.sessionID)
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }) else {
            logger.error("[MobileSync] plan decision for unknown thread=\(payload.sessionID, privacy: .public)")
            return
        }
        let window = WindowState()
        window.selectedProject = projects.first(where: { $0.id == summary.projectId })
        window.currentSessionId = sessionID
        // `respondToPlanDecision` reads `window.sessionPlanMode` to clear plan
        // mode one-shot and `window.sessionPermissionMode` for re-registration —
        // mirror the live session state into the fresh window.
        if let state = sessionStates[sessionID] {
            window.sessionPlanMode = state.planMode
            window.sessionPermissionMode = state.permissionMode
        }
        await respondToPlanDecision(
            toolUseId: payload.toolUseID,
            action: payload.toDecisionAction(),
            in: window
        )
    }

    /// Remove a resolved `AskUserQuestion` request from every window's queue and
    /// re-broadcast the (now smaller) queue to mobile.
    private func clearPendingQuestion(toolUseId: String, sessionId: String?) {
        for window in registeredWindows() {
            window.pendingPermissions.removeAll { $0.id == toolUseId }
            if window.presentedPermissionId == toolUseId {
                window.presentedPermissionId = nil
            }
        }
        mobilePendingRequests.removeValue(forKey: toolUseId)
        if let sessionId {
            broadcastMobileSessionStatus(sessionID: sessionId)
        }
        broadcastMobileQuestionQueue()
    }

    // MARK: - Plan Decision Response

    /// Resolve a Claude `ExitPlanMode` tool call based on the user's choice in the plan card.
    /// Drives both the PermissionServer hook response (allow/deny + optional reason or
    /// follow-up mode change) and the local UI bookkeeping (clear plan-mode pill, update
    /// permission chip, mark the tool block decided).
    func respondToPlanDecision(toolUseId: String, action: PlanDecisionAction, in window: WindowState) async {
        let summary: String
        let decision: PermissionDecision
        let nextMode: PermissionMode?

        switch action {
        case .acceptAsk:
            summary = "Accepted with Ask"
            decision = .allowAndSetMode(newMode: .default)
            nextMode = .default
        case .acceptWithEdits:
            summary = "Accepted with Edits"
            decision = .allowAndSetMode(newMode: .acceptEdits)
            nextMode = .acceptEdits
        case .acceptAutoApprove:
            summary = "Accepted with Auto-approve"
            decision = .allowAndSetMode(newMode: .auto)
            nextMode = .auto
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = trimmed.isEmpty ? "Rejected" : "Rejected: \(trimmed)"
            decision = .denyWithReason(reason: trimmed.isEmpty ? "User rejected the plan." : trimmed)
            nextMode = nil
        case .reject:
            summary = "Rejected"
            decision = .denyWithReason(reason: "User rejected the plan.")
            nextMode = nil
        }

        // Record the outcome on the tool block so `PlanCardView` flips from buttons to
        // a "decided" status row. This mirrors how AskUserQuestionView reads `toolCall.result`.
        // Also write into a sidecar dict that survives CLI-backed session reloads —
        // the CLI emits its own follow-up tool_result ("User has approved your plan…")
        // that overwrites `ToolCall.result` once the session jsonl is parsed fresh
        // from disk, so the in-memory result alone is not reliable.
        let key = window.currentSessionId ?? window.newSessionKey
        updateState(key) { state in
            for i in state.messages.indices.reversed() {
                if state.messages[i].toolCallIndex(id: toolUseId) != nil {
                    state.messages[i].setToolResult(id: toolUseId, result: summary, isError: false)
                    break
                }
            }
            state.planDecisionSummaries[toolUseId] = summary
        }
        threadStore.setPlanDecision(sessionId: key, toolCallId: toolUseId, summary: summary)

        // Plan-mode is one-shot — clear the pill so the next user turn isn't in plan mode.
        // This also triggers a permission re-register (no-op if there's no live CLI sid).
        if window.sessionPlanMode {
            window.sessionPlanMode = false
            updateState(key) { $0.planMode = false }
        }

        // Persist the new permission mode in the dropdown when the user opted for a
        // follow-up mode change. `setSessionPermissionMode` also re-registers with the
        // PermissionServer for the live session.
        if let nextMode {
            setSessionPermissionMode(nextMode, in: window)
        } else {
            // Even when no mode change is requested, re-register so the server registry
            // reflects the now-cleared plan-mode boolean.
            reregisterPermissionMode(in: window)
        }

        await permission.respond(toolUseId: toolUseId, decision: decision)

        // When the CLI honors `allowAndSetMode` it continues the same turn — the model
        // executes (or revises) the plan inline and the turn ends naturally. In that
        // case sending a follow-up prompt would spawn a redundant second turn that
        // reports "the work is already done". Only inject a continuation message when
        // the turn actually ended without producing any post-plan content, mirroring
        // the older CLI behavior where ExitPlanMode terminated the turn outright.
        let continuationPrompt = Self.continuationPrompt(for: action)

        if let continuationPrompt {
            if let task = sessionStates[key]?.streamTask {
                _ = await task.value
            }
            if turnContinuedAfterPlan(toolUseId: toolUseId, sessionKey: key) {
                return
            }
            await sendPrompt(
                continuationPrompt,
                skipAppendingUserMessage: true,
                in: window
            )
        }
    }

    /// True when the assistant actually *executed* the plan after the given
    /// ExitPlanMode tool call — i.e. the CLI invoked at least one other tool
    /// (Edit / Write / Bash / etc.) in the same turn, so a follow-up
    /// "Proceed with the plan." would just spawn a redundant turn. Used to
    /// gate the hidden continuation prompt.
    ///
    /// Text-only post-plan content (a brief preamble, or a recap of the plan
    /// the model already wrote into a file) does NOT count — that's the stall
    /// mode where the user is left waiting and we *do* want to inject the
    /// nudge so implementation actually starts.
    private func turnContinuedAfterPlan(toolUseId: String, sessionKey: String) -> Bool {
        guard let messages = sessionStates[sessionKey]?.messages else { return false }
        for messageIdx in messages.indices.reversed() {
            guard let planBlockIdx = messages[messageIdx].toolCallIndex(id: toolUseId) else {
                continue
            }
            // Same message: any tool-call block after the plan block counts as work.
            let trailingBlocks = messages[messageIdx].blocks.dropFirst(planBlockIdx + 1)
            if trailingBlocks.contains(where: { $0.toolCall != nil }) {
                return true
            }
            // Subsequent assistant messages: any tool-call block at all.
            if messageIdx + 1 < messages.count {
                for later in messages[(messageIdx + 1)...] where later.role == .assistant {
                    if later.blocks.contains(where: { $0.toolCall != nil }) {
                        return true
                    }
                }
            }
            return false
        }
        return false
    }

    /// Prefixes of result strings written by `respondToPlanDecision`. Sourced from
    /// `PlanDecisionAction.userDecisionResultPrefixes` so the chip in chat, the
    /// CLI-session reload guard, and the live-stream guard all share one source
    /// of truth.
    static let planDecisionResultPrefixes: [String] = PlanDecisionAction.userDecisionResultPrefixes

    static func isExitPlanModeCall(_ call: ToolCall) -> Bool {
        let n = call.name.lowercased()
        return n == "exitplanmode" || n == "exit_plan_mode"
    }

    /// Hidden follow-up prompt to send after a plan decision, or nil if the chat
    /// should stop. Plain `.reject` returns nil; `.rejectWithFeedback` with empty
    /// feedback also returns nil (the user effectively did a plain reject).
    static func continuationPrompt(for action: PlanDecisionAction) -> String? {
        switch action {
        case .acceptAsk, .acceptWithEdits, .acceptAutoApprove:
            return "Proceed with the plan."
        case .rejectWithFeedback(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? nil
                : "Revise the plan based on this feedback: \(trimmed)"
        case .reject:
            return nil
        }
    }

    // MARK: - Project Management

    func addProject(name: String, path: String, gitHubRepo: String?) async {
        guard !projects.contains(where: { $0.path == path }) else { return }
        let project = Project(name: name, path: path, gitHubRepo: gitHubRepo)
        projects.append(project)
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects: \(error.localizedDescription)")
        }
    }

    func selectProject(_ project: Project, in window: WindowState) {
        guard window.selectedProject?.id != project.id else { return }

        saveDraft(in: window)
        saveQueue(in: window)

        if isStreaming(in: window) {
            detachCurrentStream(in: window)
        }

        if let currentId = window.currentSessionId,
           let currentProject = window.selectedProject,
           let state = sessionStates[currentId],
           !state.messages.isEmpty
        {
            let title = allSessionSummaries.first(where: { $0.id == currentId })?.title ?? "Session"
            let provider = state.agentProvider ?? allSessionSummaries.first(where: { $0.id == currentId })?.agentProvider ?? selectedAgentProvider
            let origin = allSessionSummaries.first(where: { $0.id == currentId })?.origin ?? provider.defaultSessionOrigin
            let summary = allSessionSummaries.first(where: { $0.id == currentId })
            let session = ChatSession(
                id: currentId,
                projectId: currentProject.id,
                title: title,
                messages: state.messages,
                updatedAt: lastResponseDate(from: state.messages),
                isPinned: summary?.isPinned ?? false,
                agentProvider: provider,
                model: state.model,
                effort: state.effort,
                permissionMode: state.permissionMode,
                origin: origin,
                worktreePath: summary?.worktreePath,
                worktreeBranch: summary?.worktreeBranch,
                isArchived: summary?.isArchived ?? false,
                archivedAt: summary?.archivedAt
            )
            Task {
                do { try await self.persistence.saveSession(session) }
                catch { self.logger.error("Failed to save current session before project switch: \(error.localizedDescription)") }
            }
        }

        // animation: nil — all mutations land in the same frame; sessionStates.filter fires
        // one @Observable notification instead of N removeValue calls.
        withAnimation(nil) {
            window.showingBriefing = false
            window.selectedProject = project
            sessionStates = sessionStates.filter { $0.value.isStreaming }
            resetToNewChat(in: window)
        }

        activeProjectPath = project.path
        Task { await refreshMCPServers() }
        UserDefaults.standard.set(project.id.uuidString, forKey: "selectedProjectId")
    }

    func addProjectFromFolder(_ url: URL, in window: WindowState) async {
        let isGitRepo = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        let gitHubRepo = isGitRepo ? detectGitHubOwnerRepo(at: url.path) : nil
        await addAndSelectProject(name: url.lastPathComponent, path: url.path, gitHubRepo: gitHubRepo, in: window)
    }

    private func addAndSelectProject(name: String, path: String, gitHubRepo: String? = nil, in window: WindowState) async {
        if let existing = projects.first(where: { $0.path == path }) {
            selectProject(existing, in: window)
            return
        }
        await addProject(name: name, path: path, gitHubRepo: gitHubRepo)
        if let project = projects.last {
            selectProject(project, in: window)
        }
    }

    // MARK: - Session Management

    private func switchToSession(_ session: ChatSession, messages loadedMessages: [ChatMessage]? = nil, in window: WindowState) {
        let existingState = sessionStates[session.id]
        logger.info("[SwitchToSession] sid=\(session.id, privacy: .public) hasState=\(existingState != nil) existingMessages=\(existingState?.messages.count ?? -1) existingIsStreaming=\(existingState?.isStreaming ?? false) preloadedMessages=\(loadedMessages?.count ?? -1)")
        saveDraft(in: window)
        saveQueue(in: window)

        if isStreaming(in: window) {
            detachCurrentStream(in: window)
        }

        let outgoingId = window.currentSessionId

        if sessionStates[session.id] == nil {
            var state = SessionStreamState()
            state.agentProvider = session.agentProvider
            state.model = session.model
            state.effort = session.effort
            state.permissionMode = session.permissionMode
            if let msgs = loadedMessages {
                state.messages = cleanLoadedMessages(msgs)
                state.planDecisionSummaries = threadStore.loadPlanDecisions(sessionId: session.id)
                sessionStates[session.id] = state
                logger.info("[SwitchToSession] applied preloaded messages sid=\(session.id, privacy: .public) cleaned=\(state.messages.count)")
            } else {
                // Switch with an empty state first; actual messages are loaded in the background and injected later
                state.isLoadingFromDisk = true
                sessionStates[session.id] = state
                if let project = window.selectedProject {
                    logger.info("[SwitchToSession] background load triggered sid=\(session.id, privacy: .public) cwd=\(project.path, privacy: .public)")
                    loadMessagesInBackground(projectId: project.id, sessionId: session.id, cwd: project.path)
                } else {
                    logger.error("[SwitchToSession] no selectedProject — cannot load messages sid=\(session.id, privacy: .public)")
                }
            }
        } else if sessionStates[session.id]?.messages.isEmpty == true,
                  sessionStates[session.id]?.isStreaming != true,
                  let project = window.selectedProject
        {
            if var state = sessionStates[session.id] {
                if state.model == nil { state.model = session.model }
                if state.agentProvider == nil { state.agentProvider = session.agentProvider }
                if state.effort == nil { state.effort = session.effort }
                if state.permissionMode == nil { state.permissionMode = session.permissionMode }
                state.isLoadingFromDisk = true
                sessionStates[session.id] = state
            }
            logger.info("[SwitchToSession] re-loading empty cached state sid=\(session.id, privacy: .public) cwd=\(project.path, privacy: .public)")
            loadMessagesInBackground(projectId: project.id, sessionId: session.id, cwd: project.path)
        } else {
            logger.info("[SwitchToSession] reusing cached state sid=\(session.id, privacy: .public) messages=\(existingState?.messages.count ?? -1) isStreaming=\(existingState?.isStreaming ?? false)")
        }

        if sessionStates[session.id]?.isStreaming == true {
            flushPendingUpdates(for: session.id)
        }

        updateState(session.id) { $0.hasUncheckedCompletion = false }

        window.showingBriefing = false
        window.pendingWorktreePath = nil
        window.pendingWorktreeBranch = nil
        window.currentSessionId = session.id
        window.sessionAgentProvider = sessionStates[session.id]?.agentProvider ?? session.agentProvider
        window.sessionModel = sessionStates[session.id]?.model ?? session.model
        window.sessionEffort = sessionStates[session.id]?.effort ?? session.effort
        window.sessionPermissionMode = sessionStates[session.id]?.permissionMode ?? session.permissionMode
        window.sessionPlanMode = sessionStates[session.id]?.planMode ?? false
        window.inputText = window.draftTexts[session.id] ?? ""
        window.messageQueue = window.draftQueues[session.id] ?? []

        releaseOutgoingSession(outgoingId, excluding: session.id, in: window)

        if sessionStates[session.id]?.isStreaming == true {
            startFlushTimer(for: session.id)
        }
    }

    private func releaseOutgoingSession(_ outgoingId: String?, excluding newId: String? = nil, in window: WindowState) {
        guard let outgoingId,
              outgoingId != newId,
              !(sessionStates[outgoingId]?.isStreaming ?? false) else { return }
        let outgoingMessages = sessionStates[outgoingId]?.messages ?? []
        Task { [weak self] in
            guard let self else { return }
            if !outgoingMessages.isEmpty, let project = window.selectedProject {
                let summary = allSessionSummaries.first(where: { $0.id == outgoingId })
                let title = summary?.title ?? "Session"
                let state = sessionStates[outgoingId]
                let provider = state?.agentProvider ?? summary?.agentProvider ?? selectedAgentProvider
                let origin = summary?.origin ?? provider.defaultSessionOrigin
                let outgoing = ChatSession(
                    id: outgoingId,
                    projectId: project.id,
                    title: title,
                    messages: outgoingMessages,
                    updatedAt: lastResponseDate(from: outgoingMessages),
                    isPinned: summary?.isPinned ?? false,
                    agentProvider: provider,
                    model: state?.model,
                    effort: state?.effort,
                    permissionMode: state?.permissionMode,
                    origin: origin,
                    worktreePath: summary?.worktreePath,
                    worktreeBranch: summary?.worktreeBranch,
                    isArchived: summary?.isArchived ?? false,
                    archivedAt: summary?.archivedAt
                )
                do { try await persistence.saveSession(outgoing) }
                catch { logger.error("Failed to save outgoing session: \(error.localizedDescription)") }
            }
            if window.currentSessionId != outgoingId {
                sessionStates.removeValue(forKey: outgoingId)
            }
        }
    }

    private func didSwitchToSession(_ session: ChatSession) async {
        if let index = projects.firstIndex(where: { $0.id == session.projectId }) {
            projects[index].lastSessionId = session.id
            do {
                try await persistence.saveProjects(projects)
            } catch {
                logger.error("Failed to save projects: \(error.localizedDescription)")
            }
        }
    }

    func resumeSession(_ session: ChatSession, in window: WindowState) async {
        switchToSession(session, in: window)
        await didSwitchToSession(session)
    }

    // MARK: - GitHub

    func loginToGitHub() async throws -> DeviceCodeResponse {
        try await github.startDeviceFlow()
    }

    func completeGitHubLogin(deviceCode: String, interval: Int) async throws {
        _ = try await github.pollForToken(deviceCode: deviceCode, interval: interval)

        let user = try await github.fetchUser()
        gitHubUser = user
        isLoggedIn = true
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")

        do { try await persistence.saveGitHubUser(user) }
        catch { logger.error("Failed to cache GitHub user: \(error.localizedDescription)") }

        do {
            let publicKey = try await github.setupSSH()
            try await github.registerSSHKey(publicKey)
        } catch {
            logger.warning("SSH setup failed: \(error.localizedDescription)")
        }
    }

    func skipGitHubLogin() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
    }

    var isFetchingRepos = false

    func fetchRepos() async {
        isFetchingRepos = true
        defer { isFetchingRepos = false }
        do { repos = try await github.fetchRepos() }
        catch { logger.error("Failed to fetch repos: \(error.localizedDescription)") }
    }

    func cloneAndAddProject(_ repo: GitHubRepo, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(repo.name)"
        let parentDir = "\(home)/RxCode"
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        try await github.cloneRepo(repo, to: clonePath)
        await addAndSelectProject(name: repo.name, path: clonePath, gitHubRepo: repo.fullName, in: window)
    }

    func loadCustomRepos() async {
        customRepos = await persistence.loadCustomRepos()
    }

    func addCustomRepo(url: String, name: String, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(name)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: "\(home)/RxCode") {
            try fm.createDirectory(atPath: "\(home)/RxCode", withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: clonePath) {
            throw NSError(domain: "RxCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(name)' already exists in ~/RxCode"])
        }
        try await github.cloneRepo(from: url, to: clonePath)
        let repo = CustomRepo(name: name, cloneURL: url)
        customRepos.append(repo)
        try await persistence.saveCustomRepos(customRepos)
        await addAndSelectProject(name: name, path: clonePath, gitHubRepo: nil, in: window)
    }

    func cloneCustomRepo(_ repo: CustomRepo, in window: WindowState) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let clonePath = "\(home)/RxCode/\(repo.name)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: "\(home)/RxCode") {
            try fm.createDirectory(atPath: "\(home)/RxCode", withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: clonePath) {
            throw NSError(domain: "RxCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(repo.name)' already exists in ~/RxCode"])
        }
        try await github.cloneRepo(from: repo.cloneURL, to: clonePath)
        await addAndSelectProject(name: repo.name, path: clonePath, gitHubRepo: nil, in: window)
    }

    func removeCustomRepo(_ repo: CustomRepo) async {
        customRepos.removeAll { $0.id == repo.id }
        do {
            try await persistence.saveCustomRepos(customRepos)
        } catch {
            logger.error("Failed to save custom repos: \(error.localizedDescription)")
        }
    }

    // MARK: - View Convenience API

    func startNewChat(in window: WindowState) {
        if isStreaming(in: window) { detachCurrentStream(in: window) }
        saveDraft(in: window)
        saveQueue(in: window)
        releaseOutgoingSession(window.currentSessionId, in: window)
        resetToNewChat(in: window)
    }

    private func resetToNewChat(in window: WindowState) {
        window.showingBriefing = false
        window.currentSessionId = nil
        window.sessionAgentProvider = nil
        window.sessionModel = nil
        window.sessionEffort = nil
        window.sessionPermissionMode = nil
        window.sessionPlanMode = false
        window.pendingWorktreePath = nil
        window.pendingWorktreeBranch = nil
        sessionStates.removeValue(forKey: window.newSessionKey)
        window.inputText = window.draftTexts[newDraftKey(for: window)] ?? ""
        window.messageQueue = window.draftQueues[newDraftKey(for: window)] ?? []
        window.requestInputFocus = true
    }

    func renameSession(_ session: ChatSession, to newTitle: String) async {
        if let si = allSessionSummaries.firstIndex(where: { $0.id == session.id }) {
            allSessionSummaries[si].title = newTitle
            threadStore.upsert(allSessionSummaries[si])
        }
        await updateSessionMetadata(session, persistTitle: true) { $0.title = newTitle }
        broadcastMobileSessionStatus(sessionID: session.id)
    }

    /// True if `currentTitle` looks like our auto-derived placeholder (matches what
    /// `ChatSession.placeholderTitle(from:)` would produce). Used to decide whether
    /// to overwrite with an LLM-generated title — never overwrite a user's manual rename.
    private func isAutoGeneratedTitle(_ currentTitle: String, firstUserMessage: String) -> Bool {
        currentTitle == ChatSession.defaultTitle
            || currentTitle == ChatSession.placeholderTitle(from: firstUserMessage)
            || currentTitle == "New session"
            || currentTitle.isEmpty
    }

    /// Follow `sessionIdRedirect` chains to the current sid. The CLI may swap
    /// `pending-<uuid>` → real sid (and later advance the sid again on
    /// `compact_boundary`) while a long-running task holds the old id.
    private func resolveCurrentSessionId(_ id: String) -> String {
        var current = id
        var seen: Set<String> = [current]
        while let next = sessionIdRedirect[current] {
            if seen.contains(next) { break }
            seen.insert(next)
            current = next
        }
        return current
    }

    /// Spawn a one-shot summarization call to generate a 3–6 word title for the given
    /// session, then persist it via `renameSession` if the title is still the placeholder.
    /// No-op if the session was already renamed manually or the LLM call fails.
    func maybeGenerateLLMTitle(for sessionId: String) async {
        let resolved = resolveCurrentSessionId(sessionId)
        guard let summary = allSessionSummaries.first(where: { $0.id == resolved }) else {
            logger.warning("Title generation skipped: no summary for \(resolved) (original \(sessionId))")
            return
        }
        let messages = sessionStates[resolved]?.messages ?? []
        let firstUserRaw = messages.first(where: { $0.role == .user })?.content ?? ""
        let firstUser = ChatSession.stripAttachmentMarkers(from: firstUserRaw)
        guard !firstUser.isEmpty else { return }
        guard isAutoGeneratedTitle(summary.title, firstUserMessage: firstUserRaw) else { return }
        guard let title = await generateSessionTitle(firstUserMessage: firstUser, summary: summary) else { return }
        // Re-resolve after the LLM call — the id may have been swapped while we waited.
        let currentId = resolveCurrentSessionId(sessionId)
        guard let stillPlaceholder = allSessionSummaries.first(where: { $0.id == currentId }),
              isAutoGeneratedTitle(stillPlaceholder.title, firstUserMessage: firstUser) else { return }
        guard let project = projects.first(where: { $0.id == stillPlaceholder.projectId }) else { return }
        let session = ChatSession(
            id: currentId,
            projectId: project.id,
            title: title,
            messages: sessionStates[currentId]?.messages ?? messages,
            isPinned: stillPlaceholder.isPinned,
            agentProvider: stillPlaceholder.agentProvider,
            model: stillPlaceholder.model,
            effort: stillPlaceholder.effort,
            permissionMode: stillPlaceholder.permissionMode,
            origin: stillPlaceholder.origin,
            worktreePath: stillPlaceholder.worktreePath,
            worktreeBranch: stillPlaceholder.worktreeBranch,
            isArchived: stillPlaceholder.isArchived,
            archivedAt: stillPlaceholder.archivedAt
        )
        await renameSession(session, to: title)
    }

    private func generateSessionTitle(firstUserMessage: String, summary: ChatSession.Summary) async -> String? {
        switch summarizationProvider {
        case .selectedClient:
            let provider = summary.agentProvider
            let model = summary.model ?? selectedSummarizationModel(for: provider)
            return await generateSessionTitle(firstUserMessage: firstUserMessage, provider: provider, model: model)
        case .openAI:
            guard !openAISummarizationModel.isEmpty else { return nil }
            return await openAISummarization.generateSessionTitle(
                firstUserMessage: firstUserMessage,
                endpoint: openAISummarizationEndpoint,
                apiKey: openAISummarizationAPIKey,
                model: openAISummarizationModel
            )
        case .appleFoundationModel:
            return await foundationModelSummarization.generateSessionTitle(firstUserMessage: firstUserMessage)
        }
    }

    private func generateResponseNotificationSummary(responseText: String, summary: ChatSession.Summary) async -> String? {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return nil }

        switch summarizationProvider {
        case .selectedClient:
            let provider = summary.agentProvider
            let model = summary.model ?? selectedSummarizationModel(for: provider)
            return await generateResponseNotificationSummary(responseText: trimmedResponse, provider: provider, model: model)
        case .openAI:
            guard !openAISummarizationModel.isEmpty else { return nil }
            return await openAISummarization.generateResponseNotificationSummary(
                responseText: trimmedResponse,
                endpoint: openAISummarizationEndpoint,
                apiKey: openAISummarizationAPIKey,
                model: openAISummarizationModel
            )
        case .appleFoundationModel:
            return await foundationModelSummarization.generateResponseNotificationSummary(responseText: trimmedResponse)
        }
    }

    private func scheduleThreadSummaryUpdate(
        sessionId: String,
        projectId: UUID,
        cwd: String,
        messages: [ChatMessage]
    ) {
        let userMessage = lastUserMessageText(in: messages)
        let finalResponse = lastAssistantResponseText(in: messages)
        guard !userMessage.isEmpty, !finalResponse.isEmpty else { return }

        let summary = allSessionSummaries.first(where: { $0.id == sessionId })
            ?? summaryFor(sessionId: sessionId, projectId: projectId)

        Task { [weak self] in
            guard let self else { return }
            await self.updateStoredThreadSummary(
                sessionId: sessionId,
                projectId: projectId,
                cwd: cwd,
                userMessage: userMessage,
                finalResponse: finalResponse,
                summary: summary
            )
        }
    }

    private func updateStoredThreadSummary(
        sessionId: String,
        projectId: UUID,
        cwd: String,
        userMessage: String,
        finalResponse: String,
        summary: ChatSession.Summary
    ) async {
        let previousSummary = threadStore.threadSummaryItem(sessionId: sessionId)?.summary
        guard let threadSummary = await generateThreadSummary(
            previousSummary: previousSummary,
            userMessage: userMessage,
            finalResponse: finalResponse,
            summary: summary
        ) else { return }

        let branchPath = summary.worktreePath ?? cwd
        let currentBranch = await GitHelper.currentBranch(at: branchPath)
        let branch = summary.worktreeBranch ?? currentBranch ?? "unknown"
        let title = summary.title.isEmpty ? ChatSession.defaultTitle : summary.title

        threadStore.upsertThreadSummary(
            sessionId: sessionId,
            projectId: projectId,
            branch: branch,
            title: title,
            summary: threadSummary
        )
        threadSummaryRevision &+= 1

        let allThreadSummaries = threadStore
            .threadSummaryItems(projectId: projectId, branch: branch)
            .map { (title: $0.title, summary: $0.summary) }
        guard let briefing = await generateBranchBriefing(
            threadSummaries: allThreadSummaries,
            summary: summary
        ) else { return }

        threadStore.upsertBranchBriefing(projectId: projectId, branch: branch, briefing: briefing)
        branchBriefingRevision &+= 1
    }

    private func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        summary: ChatSession.Summary
    ) async -> String? {
        switch summarizationProvider {
        case .selectedClient:
            let provider = summary.agentProvider
            let model = summary.model ?? selectedSummarizationModel(for: provider)
            return await generateThreadSummary(
                previousSummary: previousSummary,
                userMessage: userMessage,
                finalResponse: finalResponse,
                provider: provider,
                model: model
            )
        case .openAI:
            guard !openAISummarizationModel.isEmpty else { return nil }
            return await openAISummarization.generateThreadSummary(
                previousSummary: previousSummary,
                userMessage: userMessage,
                finalResponse: finalResponse,
                endpoint: openAISummarizationEndpoint,
                apiKey: openAISummarizationAPIKey,
                model: openAISummarizationModel
            )
        case .appleFoundationModel:
            return await foundationModelSummarization.generateThreadSummary(
                previousSummary: previousSummary,
                userMessage: userMessage,
                finalResponse: finalResponse
            )
        }
    }

    private func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        summary: ChatSession.Summary
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        switch summarizationProvider {
        case .selectedClient:
            let provider = summary.agentProvider
            let model = summary.model ?? selectedSummarizationModel(for: provider)
            return await generateBranchBriefing(
                threadSummaries: threadSummaries,
                provider: provider,
                model: model
            )
        case .openAI:
            guard !openAISummarizationModel.isEmpty else { return nil }
            return await openAISummarization.generateBranchBriefing(
                threadSummaries: threadSummaries,
                endpoint: openAISummarizationEndpoint,
                apiKey: openAISummarizationAPIKey,
                model: openAISummarizationModel
            )
        case .appleFoundationModel:
            return await foundationModelSummarization.generateBranchBriefing(threadSummaries: threadSummaries)
        }
    }

    /// Generates a commit message for the staged changes in the given project.
    /// Routes through the configured `summarizationProvider`. Returns nil on
    /// failure or when no provider is configured. Public so the Changes view
    /// can invoke it from the UI thread.
    ///
    /// `diff` and `stat` should come from `GitHelper.stagedDiff` /
    /// `GitHelper.stagedStat`. We compact them per-provider so very large
    /// patches don't blow past the model's context window — the small
    /// on-device Foundation Model gets a much tighter budget than the
    /// cloud-hosted providers.
    func generateCommitMessage(
        diff: String,
        stat: String,
        fileSummary: String
    ) async -> String? {
        let raw: String?
        switch summarizationProvider {
        case .appleFoundationModel:
            let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
            raw = await foundationModelSummarization.generateCommitMessage(
                diff: context,
                fileSummary: fileSummary
            )
        case .openAI:
            if openAISummarizationModel.isEmpty {
                if FoundationModelSummarizationService.isAvailable {
                    let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
                    raw = await foundationModelSummarization.generateCommitMessage(
                        diff: context,
                        fileSummary: fileSummary
                    )
                } else {
                    raw = nil
                }
            } else {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 16_000)
                raw = await openAISummarization.generateCommitMessage(
                    diff: context,
                    fileSummary: fileSummary,
                    endpoint: openAISummarizationEndpoint,
                    apiKey: openAISummarizationAPIKey,
                    model: openAISummarizationModel
                )
            }
        case .selectedClient:
            if FoundationModelSummarizationService.isAvailable {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
                raw = await foundationModelSummarization.generateCommitMessage(
                    diff: context,
                    fileSummary: fileSummary
                )
            } else {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 16_000)
                raw = await claude.generateCommitMessage(diff: context, fileSummary: fileSummary)
            }
        }
        return Self.sanitizeCommitMessage(raw)
    }

    /// Builds a compact diff context that fits within `budget` characters.
    /// When the raw diff fits, returns it as-is (prefixed with the stat).
    /// When it doesn't, splits by `diff --git` boundaries and gives each file
    /// a fair share of the remaining budget — keeping the header plus the
    /// leading lines of the patch so the model still sees what changed in
    /// each file, even if deeper context is dropped.
    static func buildCommitContext(diff: String, stat: String, budget: Int) -> String {
        let statBlock: String = {
            let trimmed = stat.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : "Diff stat:\n\(trimmed)\n\n"
        }()

        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDiff.isEmpty {
            return statBlock + "Full diff:\n(none)"
        }

        // Fast path — total fits within budget.
        if statBlock.count + trimmedDiff.count <= budget {
            return statBlock + "Full diff:\n" + trimmedDiff
        }

        // Split by file boundaries. The first chunk before any "diff --git" is
        // ignored (git always starts file blocks with that marker).
        let marker = "\ndiff --git "
        var fileBlocks: [String] = []
        var remaining = "\n" + trimmedDiff
        while let range = remaining.range(of: marker) {
            let nextStart = remaining.index(range.lowerBound, offsetBy: 1) // drop leading "\n"
            if let next = remaining.range(of: marker, range: range.upperBound..<remaining.endIndex) {
                fileBlocks.append(String(remaining[nextStart..<next.lowerBound]))
                remaining = String(remaining[next.lowerBound..<remaining.endIndex])
            } else {
                fileBlocks.append(String(remaining[nextStart..<remaining.endIndex]))
                remaining = ""
            }
        }
        if fileBlocks.isEmpty {
            // No "diff --git" markers found — fall back to a head clip.
            let clipped = String(trimmedDiff.prefix(max(0, budget - statBlock.count - 64)))
            return statBlock + "Full diff (truncated):\n" + clipped + "\n…[truncated]"
        }

        let budgetForDiffs = max(0, budget - statBlock.count - 64)
        let perFile = max(300, budgetForDiffs / fileBlocks.count)
        var assembled = ""
        for block in fileBlocks {
            if block.count <= perFile {
                assembled += block
            } else {
                let head = String(block.prefix(perFile))
                assembled += head + "\n…[file diff truncated]\n"
            }
            if assembled.count >= budgetForDiffs { break }
        }

        return statBlock + "Truncated diff (file-by-file):\n" + assembled
    }

    /// Strips markdown wrappers and ensures the message starts with a
    /// Conventional Commits `type:` line. Defends against models that add
    /// headings, code fences, or quoted text despite explicit prompts.
    private static func sanitizeCommitMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // Strip fenced code blocks: ```...``` (any language tag).
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last?.trimmingCharacters(in: .whitespaces), last == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip surrounding quotes/backticks if the whole message is wrapped.
        if let first = text.first, let last = text.last,
           "\"'`".contains(first), first == last, text.count > 1 {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop leading lines that look like markdown headings or empty lines
        // until we reach a Conventional Commits subject (or any plain text).
        let conventionalPrefixes = [
            "feat", "fix", "docs", "style", "refactor", "perf",
            "test", "build", "ci", "chore", "revert"
        ]
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            let isEmpty = trimmed.isEmpty
            let startsWithType = conventionalPrefixes.contains { type in
                trimmed.lowercased().hasPrefix(type + ":") ||
                trimmed.lowercased().hasPrefix(type + "(")
            }
            if startsWithType { break }
            if isHeading || isEmpty {
                lines.removeFirst()
                continue
            }
            break
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func generateSessionTitle(firstUserMessage: String, provider: AgentProvider, model: String?) async -> String? {
        switch provider {
        case .claudeCode:
            return await claude.generateSessionTitle(firstUserMessage: firstUserMessage, model: model ?? "haiku")
        case .codex:
            return await codex.generateSessionTitle(firstUserMessage: firstUserMessage, model: model)
        case .acp:
            // No standardized title-generation in ACP; fall back to the truncation logic upstream.
            return nil
        }
    }

    private func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        provider: AgentProvider,
        model: String?
    ) async -> String? {
        switch provider {
        case .claudeCode:
            return await claude.generateThreadSummary(
                previousSummary: previousSummary,
                userMessage: userMessage,
                finalResponse: finalResponse,
                model: model ?? "haiku"
            )
        case .codex:
            return await codex.generateThreadSummary(
                previousSummary: previousSummary,
                userMessage: userMessage,
                finalResponse: finalResponse,
                model: model
            )
        case .acp:
            return nil
        }
    }

    private func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        provider: AgentProvider,
        model: String?
    ) async -> String? {
        switch provider {
        case .claudeCode:
            return await claude.generateBranchBriefing(
                threadSummaries: threadSummaries,
                model: model ?? "haiku"
            )
        case .codex:
            return await codex.generateBranchBriefing(
                threadSummaries: threadSummaries,
                model: model
            )
        case .acp:
            return nil
        }
    }

    private func generateResponseNotificationSummary(responseText: String, provider: AgentProvider, model: String?) async -> String? {
        switch provider {
        case .claudeCode:
            return await claude.generateResponseNotificationSummary(responseText: responseText, model: model ?? "haiku")
        case .codex:
            return await codex.generateResponseNotificationSummary(responseText: responseText, model: model)
        case .acp:
            // No standardized one-shot generation in ACP; keep the local preview fallback.
            return nil
        }
    }

    private func lastAssistantResponseText(in messages: [ChatMessage]) -> String {
        guard let message = messages.last(where: { $0.role == .assistant && !$0.isError }) else {
            return ""
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lastUserMessageText(in messages: [ChatMessage]) -> String {
        guard let message = messages.last(where: { $0.role == .user && !$0.isError }) else {
            return ""
        }
        return ChatSession.stripAttachmentMarkers(from: message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func responseNotificationFallback(from responseText: String) -> String {
        let text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let sentence = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? text
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    private func selectedSummarizationModel(for provider: AgentProvider) -> String? {
        if selectedAgentProvider == provider {
            return selectedModel
        }
        return availableAgentModelSections()
            .first(where: { $0.provider == provider })?
            .models
            .first?
            .id
    }

    func togglePinSession(_ session: ChatSession) async {
        guard let si = allSessionSummaries.firstIndex(where: { $0.id == session.id }) else { return }
        allSessionSummaries[si].isPinned.toggle()
        let newIsPinned = allSessionSummaries[si].isPinned
        threadStore.upsert(allSessionSummaries[si])
        await updateSessionMetadata(session) { $0.isPinned = newIsPinned }
        scheduleMobileSnapshotBroadcast()
    }

    // MARK: - Archive

    func archiveSession(_ session: ChatSession, in window: WindowState) async {
        await setArchived(session, archived: true, in: window)
    }

    func unarchiveSession(_ session: ChatSession, in window: WindowState? = nil) async {
        if let window {
            await setArchived(session, archived: false, in: window)
        } else {
            await setArchivedNoWindow(session, archived: false)
        }
    }

    private func setArchived(_ session: ChatSession, archived: Bool, in window: WindowState) async {
        // If the chat being archived is currently open in this window, swap to a
        // fresh session so the user isn't stranded staring at a now-hidden chat.
        if archived, window.currentSessionId == session.id {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }
        await setArchivedNoWindow(session, archived: archived)
    }

    private func setArchivedNoWindow(_ session: ChatSession, archived: Bool) async {
        let now = Date()
        if let si = allSessionSummaries.firstIndex(where: { $0.id == session.id }) {
            allSessionSummaries[si].isArchived = archived
            allSessionSummaries[si].archivedAt = archived ? now : nil
            threadStore.upsert(allSessionSummaries[si])
        } else {
            _ = threadStore.setArchived(id: session.id, archived: archived, at: now)
        }
        await updateSessionMetadata(session) { s in
            s.isArchived = archived
            s.archivedAt = archived ? now : nil
        }
        scheduleMobileSnapshotBroadcast()
    }

    /// Retention window (days) after which a branch briefing is purged if its
    /// branch hasn't been observed locally or remotely. A branch deleted both
    /// places will simply stop being touched and age out.
    private static let branchBriefingRetentionDays = 30

    /// Mark a branch as still alive on disk so its briefing isn't garbage-
    /// collected. Called from views that have just observed the branch via
    /// `git symbolic-ref` or similar.
    func touchBranchBriefing(projectId: UUID, branch: String) {
        threadStore.touchBranchBriefing(projectId: projectId, branch: branch)
    }

    /// Delete branch briefings for branches that haven't been seen for the
    /// retention window. Run once at app launch.
    func purgeStaleBranchBriefingsIfNeeded() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -Self.branchBriefingRetentionDays,
            to: Date()
        ) ?? Date()
        let purged = threadStore.purgeStaleBranchBriefings(olderThan: cutoff)
        guard !purged.isEmpty else { return }
        branchBriefingRevision &+= 1
        logger.info("Purged \(purged.count) stale branch briefings older than \(Self.branchBriefingRetentionDays) days")
    }

    /// Apply the auto-archive policy: archive non-pinned chats whose `updatedAt`
    /// is older than `archiveRetentionDays`. Run once at app launch.
    func autoArchiveExpiredSessionsIfNeeded() {
        guard autoArchiveEnabled else { return }
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -archiveRetentionDays,
            to: Date()
        ) ?? Date()
        let archivedIds = threadStore.archiveStale(olderThan: cutoff)
        guard !archivedIds.isEmpty else { return }
        let idSet = Set(archivedIds)
        let now = Date()
        for idx in allSessionSummaries.indices where idSet.contains(allSessionSummaries[idx].id) {
            allSessionSummaries[idx].isArchived = true
            allSessionSummaries[idx].archivedAt = now
        }
        logger.info("Auto-archived \(archivedIds.count) chats older than \(self.archiveRetentionDays) days")
    }

    /// Persist a metadata-only edit (title, pin, etc.) routing by session
    /// origin. cliBacked sessions go to the sidecar; legacy sessions need the
    /// full message log to be re-saved alongside the change.
    /// `persistTitle` should be true only for explicit user renames; pin and
    /// other non-title edits leave the sidecar title untouched so it stays
    /// in sync with the CLI's first-message-derived label.

    // MARK: - Worktree

    /// Create a Git worktree for the chat and remember it on the session.
    /// Subsequent CLI invocations for this session will run in the worktree.
    func attachWorktree(branch: String, in window: WindowState) async throws {
        guard let project = window.selectedProject else {
            throw AppError.noProjectSelected
        }
        let baseRepo = URL(fileURLWithPath: project.path)
        let info = try await GitWorktreeService.shared.createWorktree(
            baseRepo: baseRepo,
            branch: branch
        )

        // New-chat view: no session yet. Park the worktree on the window so
        // it gets applied when sendPrompt allocates a session id.
        guard let sessionId = window.currentSessionId else {
            window.pendingWorktreePath = info.path.path
            window.pendingWorktreeBranch = info.branch
            return
        }

        // Update in-memory state
        sessionStates[sessionId, default: SessionStreamState()].worktreePath = info.path.path
        sessionStates[sessionId, default: SessionStreamState()].worktreeBranch = info.branch
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = info.path.path
            allSessionSummaries[idx].worktreeBranch = info.branch
            threadStore.upsert(allSessionSummaries[idx])
        }
        // Persist via sidecar meta
        let snap = allSessionSummaries.first(where: { $0.id == sessionId })
        let fallbackProvider = defaultModelSelection(for: project).provider
        let updated = (snap ?? ChatSession.Summary(
            id: sessionId, projectId: project.id, title: ChatSession.defaultTitle,
            createdAt: Date(), updatedAt: Date(), isPinned: false,
            agentProvider: sessionStates[sessionId]?.agentProvider ?? fallbackProvider,
            worktreePath: info.path.path, worktreeBranch: info.branch
        )).makeSession()
        await updateSessionMetadata(updated) { s in
            s.worktreePath = info.path.path
            s.worktreeBranch = info.branch
        }
    }

    /// Switch the chat to an existing branch.
    ///
    /// If the branch is already attached to a linked worktree, point the
    /// session at that worktree. Otherwise run `git checkout` in the project
    /// root and clear the session's worktree pointer.
    func switchToExistingBranch(_ branch: String, in window: WindowState) async throws {
        guard let project = window.selectedProject else {
            throw AppError.noProjectSelected
        }
        let baseRepo = URL(fileURLWithPath: project.path)

        let existingWorktree: GitWorktreeService.WorktreeInfo? = await {
            guard let list = try? await GitWorktreeService.shared.listWorktrees(baseRepo: baseRepo) else {
                return nil
            }
            // The main repo also appears in `worktree list`; skip it so the
            // project root takes the plain-checkout path.
            return list.first { $0.branch == branch && $0.path.standardizedFileURL != baseRepo.standardizedFileURL }
        }()

        let newPath: String?
        let newBranch: String?
        if let existingWorktree {
            newPath = existingWorktree.path.path
            newBranch = existingWorktree.branch
        } else {
            if let err = await GitHelper.checkout(branch: branch, at: project.path) {
                throw GitWorktreeService.WorktreeError.gitFailed(err)
            }
            newPath = nil
            newBranch = nil
        }

        guard let sessionId = window.currentSessionId else {
            window.pendingWorktreePath = newPath
            window.pendingWorktreeBranch = newBranch
            return
        }

        sessionStates[sessionId, default: SessionStreamState()].worktreePath = newPath
        sessionStates[sessionId, default: SessionStreamState()].worktreeBranch = newBranch
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = newPath
            allSessionSummaries[idx].worktreeBranch = newBranch
            threadStore.upsert(allSessionSummaries[idx])
        }
        if let snap = allSessionSummaries.first(where: { $0.id == sessionId }) {
            await updateSessionMetadata(snap.makeSession()) { s in
                s.worktreePath = newPath
                s.worktreeBranch = newBranch
            }
        }
    }

    /// Remove the worktree associated with the session (if any).
    /// `force = true` removes even with uncommitted changes.
    func detachWorktree(in window: WindowState, force: Bool = false) async throws {
        guard let sessionId = window.currentSessionId else { return }
        let path = sessionStates[sessionId]?.worktreePath
            ?? allSessionSummaries.first(where: { $0.id == sessionId })?.worktreePath
        guard let path else { return }
        try await GitWorktreeService.shared.removeWorktree(URL(fileURLWithPath: path), force: force)
        sessionStates[sessionId]?.worktreePath = nil
        sessionStates[sessionId]?.worktreeBranch = nil
        if let idx = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            allSessionSummaries[idx].worktreePath = nil
            allSessionSummaries[idx].worktreeBranch = nil
            threadStore.upsert(allSessionSummaries[idx])
        }
        if let snap = allSessionSummaries.first(where: { $0.id == sessionId }) {
            await updateSessionMetadata(snap.makeSession()) { s in
                s.worktreePath = nil
                s.worktreeBranch = nil
            }
        }
    }

    /// Returns the current effective working directory for the active chat —
    /// either the chat's worktree (if attached) or the project path.
    func effectiveCwd(in window: WindowState) -> String? {
        guard let project = window.selectedProject else { return nil }
        if let sid = window.currentSessionId {
            if let p = sessionStates[sid]?.worktreePath { return p }
            if let p = allSessionSummaries.first(where: { $0.id == sid })?.worktreePath { return p }
        }
        return project.path
    }

    private func updateSessionMetadata(
        _ session: ChatSession,
        persistTitle: Bool = false,
        mutate: (inout ChatSession) -> Void
    ) async {
        let summary = allSessionSummaries.first(where: { $0.id == session.id }) ?? session.summary
        var updated: ChatSession = switch summary.origin {
        case .cliBacked:
            summary.makeSession()
        case .legacyRxCode, .codexAppServer, .acpAgent:
            persistence.loadLegacySessionSync(projectId: session.projectId, sessionId: session.id) ?? session
        }
        mutate(&updated)
        do { try await persistence.saveSession(updated, persistTitle: persistTitle) }
        catch { logger.error("Failed to save session metadata: \(error.localizedDescription)") }
    }

    func renameProject(_ project: Project, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = trimmed
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects after rename: \(error.localizedDescription)")
        }
    }

    func deleteProject(_ project: Project, in window: WindowState) async {
        // Switch away if the deleted project is currently selected
        if window.selectedProject?.id == project.id {
            let next = projects.first(where: { $0.id != project.id })
            if let next {
                selectProject(next, in: window)
            } else {
                window.selectedProject = nil
                window.currentSessionId = nil
            }
        }

        // Cascade: delete each session's stored messages (CLI jsonl, meta,
        // legacy json) before discarding the project itself. Without this the
        // jsonls remain on disk under the project's cwd and would resurface as
        // orphan sessions if the same path is added back as a project later.
        let projectSummaries = allSessionSummaries.filter { $0.projectId == project.id }
        for summary in projectSummaries {
            let cwd = summary.worktreePath ?? project.path
            do {
                try await persistence.deleteSession(
                    projectId: summary.projectId,
                    sessionId: summary.id,
                    origin: summary.origin,
                    cwd: cwd
                )
            } catch {
                logger.error("Failed to delete session \(summary.id) on project delete: \(error.localizedDescription)")
            }
            sessionStates.removeValue(forKey: summary.id)
        }

        // Remove all in-memory session summaries for this project
        threadStore.deleteAll(projectId: project.id)
        let projectId = project.id
        Task.detached(priority: .utility) { [searchService] in await searchService.removeProject(id: projectId) }
        allSessionSummaries.removeAll { $0.projectId == project.id }

        // Remove from projects list and persist
        projects.removeAll { $0.id == project.id }
        do {
            try await persistence.saveProjects(projects)
        } catch {
            logger.error("Failed to save projects after deletion: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ session: ChatSession, in window: WindowState) async {
        if window.currentSessionId == session.id {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }
        let summary = allSessionSummaries.first(where: { $0.id == session.id })
        let origin = summary?.origin ?? session.origin
        // Prefer the worktreePath used while writing the jsonl — otherwise the
        // CLI jsonl (stored under that cwd) is orphaned on disk and resurrects
        // on next reload. Fall back to the project's path, then the session's.
        let cwd = summary?.worktreePath
            ?? session.worktreePath
            ?? projects.first(where: { $0.id == session.projectId })?.path
        do {
            try await persistence.deleteSession(projectId: session.projectId, sessionId: session.id, origin: origin, cwd: cwd)
        } catch {
            logger.error("Failed to delete session: \(error.localizedDescription)")
        }
        allSessionSummaries.removeAll { $0.id == session.id }
        threadStore.delete(id: session.id)
        let deletedId = session.id
        Task.detached(priority: .utility) { [searchService] in await searchService.removeThread(id: deletedId) }
        sessionStates.removeValue(forKey: session.id)
    }

    func deleteAllSessions(projectId: UUID? = nil, archivedOnly: Bool = false, in window: WindowState) async {
        var toDelete: [ChatSession.Summary]
        if let projectId {
            toDelete = allSessionSummaries.filter { $0.projectId == projectId }
        } else {
            toDelete = allSessionSummaries
        }
        if archivedOnly {
            toDelete = toDelete.filter { $0.isArchived }
        }
        let ids = Set(toDelete.map(\.id))

        // Only disrupt the current window's stream if its session is actually
        // being deleted — otherwise a project-scoped delete would clobber an
        // unrelated streaming session.
        if let currentId = window.currentSessionId, ids.contains(currentId) {
            detachCurrentStream(in: window)
            startNewChat(in: window)
        }

        for summary in toDelete {
            let cwd = summary.worktreePath
                ?? projects.first(where: { $0.id == summary.projectId })?.path
            do {
                try await persistence.deleteSession(
                    projectId: summary.projectId,
                    sessionId: summary.id,
                    origin: summary.origin,
                    cwd: cwd
                )
            } catch {
                logger.error("Failed to delete session \(summary.id): \(error.localizedDescription)")
            }
        }

        allSessionSummaries.removeAll { ids.contains($0.id) }
        if archivedOnly {
            for id in ids {
                threadStore.delete(id: id)
            }
            let snapshotIds = ids
            Task.detached(priority: .utility) { [searchService] in
                for id in snapshotIds { await searchService.removeThread(id: id) }
            }
        } else {
            threadStore.deleteAll(projectId: projectId)
            if let projectId {
                Task.detached(priority: .utility) { [searchService] in await searchService.removeProject(id: projectId) }
            } else {
                let snapshotIds = ids
                Task.detached(priority: .utility) { [searchService] in
                    for id in snapshotIds { await searchService.removeThread(id: id) }
                }
            }
        }
        for id in ids {
            sessionStates.removeValue(forKey: id)
        }
    }

    func selectSession(id: String, in window: WindowState) {
        logger.info("[SelectSession] click sid=\(id, privacy: .public) currentSid=\(window.currentSessionId ?? "<nil>", privacy: .public) selectedProject=\(window.selectedProject?.id.uuidString ?? "<nil>", privacy: .public) summariesCount=\(self.allSessionSummaries.count)")
        guard window.currentSessionId != id else {
            if window.showingBriefing {
                window.showingBriefing = false
                window.requestInputFocus = true
                logger.info("[SelectSession] same sid, leaving briefing sid=\(id, privacy: .public)")
            } else {
                logger.info("[SelectSession] no-op: already current sid=\(id, privacy: .public)")
            }
            return
        }

        window.cancelSessionSwitchTask()

        if let summary = allSessionSummaries.first(where: { $0.id == id }),
           summary.projectId == window.selectedProject?.id
        {
            logger.info("[SelectSession] match in current project sid=\(id, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public) title=\(summary.title, privacy: .public)")
            let session = summary.makeSession()
            switchToSession(session, in: window)
            window.requestInputFocus = true
            window.setSessionSwitchTask(Task {
                guard !Task.isCancelled else { return }
                await didSwitchToSession(session)
            })
            return
        }

        // If it's a session from another project, switch the project as well
        guard let summary = allSessionSummaries.first(where: { $0.id == id }),
              let project = projects.first(where: { $0.id == summary.projectId })
        else {
            logger.error("[SelectSession] summary or project missing for sid=\(id, privacy: .public)")
            return
        }

        logger.info("[SelectSession] cross-project switch sid=\(id, privacy: .public) toProject=\(project.id.uuidString, privacy: .public)")
        window.setSessionSwitchTask(Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            selectProject(project, in: window)
            guard !Task.isCancelled else { return }
            if let s = allSessionSummaries.first(where: { $0.id == id }) {
                let session = s.makeSession()
                if sessionStates[session.id] == nil,
                   let full = await persistence.loadFullSession(summary: s, cwd: project.path)
                {
                    logger.info("[SelectSession] cross-project preload ok sid=\(id, privacy: .public) messages=\(full.messages.count)")
                    switchToSession(full, messages: full.messages, in: window)
                } else {
                    logger.info("[SelectSession] cross-project preload empty sid=\(id, privacy: .public)")
                    switchToSession(session, in: window)
                }
                window.requestInputFocus = true
                await didSwitchToSession(session)
            }
        })
    }

    func addProject(_ project: Project) {
        guard !projects.contains(where: { $0.path == project.path }) else { return }
        projects.append(project)
        Task {
            do { try await persistence.saveProjects(projects) }
            catch { logger.error("Failed to save projects: \(error.localizedDescription)") }
        }
    }

    // MARK: - Marketplace

    func loadMarketplace(forceRefresh: Bool = false) async {
        marketplaceLoading = true
        marketplaceSourceError = nil
        defer { marketplaceLoading = false }

        async let catalog = marketplace.fetchCatalog(forceRefresh: forceRefresh)
        async let installed = marketplace.installedPluginNames()

        let fetchedCatalog = await catalog
        let installedNames = await installed
        await marketplace.importInstalledPlugins(catalog: fetchedCatalog, installedNames: installedNames)

        marketplaceCatalog = fetchedCatalog
        marketplaceInstalledNames = installedNames
        marketplaceCustomSources = await marketplace.customSources()
    }

    func installMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        marketplacePluginStates[plugin.id] = .installing
        do {
            try await marketplace.installPlugin(plugin)
            marketplacePluginStates[plugin.id] = .installed
            marketplaceInstalledNames.insert(plugin.name)
        } catch {
            marketplacePluginStates[plugin.id] = .failed(error.localizedDescription)
            logger.error("Failed to install plugin \(plugin.name): \(error.localizedDescription)")
        }
    }

    func uninstallMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        do {
            try await marketplace.uninstallPlugin(plugin)
            marketplaceInstalledNames.remove(plugin.name)
            marketplacePluginStates[plugin.id] = .notInstalled
        } catch {
            logger.error("Failed to uninstall plugin \(plugin.name): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func addMarketplaceGitSource(url: String, ref: String?) async -> Bool {
        marketplaceSourceError = nil
        do {
            _ = try await marketplace.addCustomGitSource(url: url, ref: ref)
            marketplaceCustomSources = await marketplace.customSources()
            await loadMarketplace(forceRefresh: true)
            return true
        } catch {
            marketplaceSourceError = error.localizedDescription
            logger.error("Failed to add marketplace Git source: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeMarketplaceGitSource(_ source: MarketplaceCustomSource) async -> Bool {
        marketplaceSourceError = nil
        do {
            try await marketplace.removeCustomGitSource(source)
            marketplaceCustomSources = await marketplace.customSources()
            await loadMarketplace(forceRefresh: true)
            return true
        } catch {
            marketplaceSourceError = error.localizedDescription
            logger.error("Failed to remove marketplace Git source: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Attachment Management

    func addAttachment(_ attachment: Attachment, in window: WindowState) {
        window.attachments.append(attachment)
    }

    func removeAttachment(_ id: UUID, in window: WindowState) {
        window.removeAttachment(id)
    }

    private func buildPromptWithAttachments(_ text: String, attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let attachmentLines = attachments.map(\.promptContext).joined(separator: "\n")
        let userText = text.isEmpty ? "See attached files" : text
        return "\(attachmentLines)\n\n\(userText)"
    }

    // MARK: - Private Helpers

    /// Extract the last response time from the message list. Based on the last assistant message; falls back to the last message, then current time.
    private func lastResponseDate(from messages: [ChatMessage]) -> Date {
        messages.last(where: { $0.role == .assistant })?.timestamp
            ?? messages.last?.timestamp
            ?? Date()
    }

    private func cleanLoadedMessages(_ raw: [ChatMessage]) -> [ChatMessage] {
        raw.compactMap { message in
            var msg = message
            msg.isStreaming = false
            if msg.blocks.isEmpty, msg.role == .assistant { return nil }
            return msg
        }
    }

    /// Last seen jsonl byte size per session — used as a cheap drift signal
    /// in `reconcileFromDisk` so the no-drift path skips the full mmap+parse.
    private var lastReconciledJsonlSize: [String: UInt64] = [:]

    /// Build the routing summary for `persistence.loadFullSession`. Falls back
    /// to a synthesized `.cliBacked` summary when the session hasn't been
    /// indexed yet (e.g. brand-new session whose `.result` arrived before the
    /// summary list refresh).
    private func summaryFor(sessionId: String, projectId: UUID) -> ChatSession.Summary {
        let fallbackProvider = defaultModelSelection(for: projects.first { $0.id == projectId }).provider
        return allSessionSummaries.first(where: { $0.id == sessionId })
            ?? ChatSession.Summary(
                id: sessionId, projectId: projectId, title: "",
                createdAt: Date(), updatedAt: Date(), isPinned: false,
                agentProvider: sessionStates[sessionId]?.agentProvider ?? fallbackProvider,
                origin: (sessionStates[sessionId]?.agentProvider ?? fallbackProvider).defaultSessionOrigin
            )
    }

    /// Reload messages from the CLI's jsonl on disk and fill any blocks the
    /// live stream may have missed (e.g. ownership-transfer races, observation
    /// re-subscribe gaps). Fired off as a detached task so the stream loop is
    /// not delayed by the mmap parse.
    ///
    /// Replacement is gated on disk having strictly more block content than
    /// memory, so the common no-drift case produces no UI churn. Before the
    /// parse, the file size is compared against the last seen size — if the
    /// jsonl hasn't grown, the parse is skipped entirely.
    private func reconcileFromDisk(sessionId: String, projectId: UUID, cwd: String) {
        let summary = summaryFor(sessionId: sessionId, projectId: projectId)
        let lastSize = lastReconciledJsonlSize[sessionId]

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let url = await self.cliStore.directory(forCwd: cwd)
                .appendingPathComponent("\(sessionId).jsonl")
            let currentSize: UInt64? = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int)
                .flatMap(UInt64.init(exactly:))
            if let lastSize, let currentSize, currentSize <= lastSize { return }

            guard let full = await self.persistence.loadFullSession(summary: summary, cwd: cwd) else { return }
            let cleaned = await self.cleanLoadedMessages(full.messages)
            await MainActor.run {
                guard var state = self.sessionStates[sessionId], !state.isStreaming else { return }
                if let currentSize { self.lastReconciledJsonlSize[sessionId] = currentSize }
                let memBlocks = state.messages.reduce(0) { $0 + $1.blocks.count }
                let diskBlocks = cleaned.reduce(0) { $0 + $1.blocks.count }
                guard diskBlocks > memBlocks else { return }
                self.logger.info("[Reconcile] sid=\(sessionId, privacy: .public) memBlocks=\(memBlocks) diskBlocks=\(diskBlocks) — applied")
                state.messages = cleaned
                self.sessionStates[sessionId] = state
            }
        }
    }

    /// Load messages in the background and inject without blocking the main thread.
    /// Does not overwrite if currently streaming or if messages already exist.
    /// `cwd` is needed so we can route to the CLI's jsonl when origin is `.cliBacked`.
    private func loadMessagesInBackground(projectId: UUID, sessionId: String, cwd: String) {
        // Snapshot the summary while we're on MainActor so the detached task
        // can route by origin without awaiting back to us first.
        let summary = summaryFor(sessionId: sessionId, projectId: projectId)
        logger.info("[LoadMessages] start sid=\(sessionId, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public) cwd=\(cwd, privacy: .public)")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let full = await self.persistence.loadFullSession(summary: summary, cwd: cwd)
            let cleaned: [ChatMessage]
            if let full {
                cleaned = await self.cleanLoadedMessages(full.messages)
            } else {
                cleaned = []
            }
            await MainActor.run {
                let rawCount = full?.messages.count ?? -1
                self.logger.info("[LoadMessages] loaded sid=\(sessionId, privacy: .public) rawMessages=\(rawCount) cleaned=\(cleaned.count)")
                guard var state = self.sessionStates[sessionId] else {
                    self.logger.error("[LoadMessages] dropped — no sessionState sid=\(sessionId, privacy: .public)")
                    return
                }
                // Always clear the loading flag, even if we bail out — otherwise the UI
                // would stay faded out forever on the failure / skip paths.
                state.isLoadingFromDisk = false
                defer { self.sessionStates[sessionId] = state }
                guard let full else {
                    self.logger.error("[LoadMessages] no session returned by persistence sid=\(sessionId, privacy: .public) origin=\(String(describing: summary.origin), privacy: .public)")
                    return
                }
                guard !state.isStreaming, state.messages.isEmpty else {
                    self.logger.info("[LoadMessages] skipped apply sid=\(sessionId, privacy: .public) isStreaming=\(state.isStreaming) existingMessages=\(state.messages.count)")
                    return
                }
                state.messages = cleaned
                state.planDecisionSummaries = self.threadStore.loadPlanDecisions(sessionId: sessionId)
                if state.model == nil { state.model = full.model }
                if state.effort == nil { state.effort = full.effort }
                if state.permissionMode == nil { state.permissionMode = full.permissionMode }
                self.logger.info("[LoadMessages] applied sid=\(sessionId, privacy: .public) messages=\(state.messages.count) planDecisions=\(state.planDecisionSummaries.count)")
            }
        }
    }

    private func saveCurrentSession(in window: WindowState) async {
        guard let project = window.selectedProject,
              let sessionId = window.currentSessionId else { return }
        await saveSession(
            sessionId: sessionId,
            projectId: project.id,
            messages: stateForSession(sessionId).messages
        )
    }

    private func saveSession(sessionId: String, projectId: UUID, messages: [ChatMessage]) async {
        guard !messages.isEmpty else { return }

        // Preserve the existing title (which may have been renamed by the user or
        // generated by the LLM). Fall back to the default placeholder; the LLM
        // title generator replaces it once the first assistant reply arrives.
        let summary = allSessionSummaries.first(where: { $0.id == sessionId })
        let title: String
        if let existing = summary, !existing.title.isEmpty {
            title = existing.title
        } else {
            title = ChatSession.defaultTitle
        }

        let sessionModel = sessionStates[sessionId]?.model
            ?? summary?.model
        let sessionAgentProvider = sessionStates[sessionId]?.agentProvider
            ?? summary?.agentProvider
            ?? selectedAgentProvider
        let sessionEffort = sessionStates[sessionId]?.effort
            ?? summary?.effort
        let sessionPermissionMode = sessionStates[sessionId]?.permissionMode
            ?? summary?.permissionMode
        let origin = summary?.origin
            ?? sessionAgentProvider.defaultSessionOrigin
        let session = ChatSession(
            id: sessionId,
            projectId: projectId,
            title: title,
            messages: messages,
            updatedAt: lastResponseDate(from: messages),
            isPinned: summary?.isPinned ?? false,
            agentProvider: sessionAgentProvider,
            model: sessionModel,
            effort: sessionEffort,
            permissionMode: sessionPermissionMode,
            origin: origin,
            worktreePath: summary?.worktreePath,
            worktreeBranch: summary?.worktreeBranch,
            isArchived: summary?.isArchived ?? false,
            archivedAt: summary?.archivedAt
        )

        do {
            try await persistence.saveSession(session)
        } catch {
            logger.error("Failed to save session \(sessionId): \(error.localizedDescription)")
        }

        // Update allSessionSummaries — skipped while streaming (updated only once after completion)
        let isCurrentlyStreaming = sessionStates[sessionId]?.isStreaming ?? false
        if !isCurrentlyStreaming {
            let summary = session.summary
            withAnimation(nil) {
                while allSessionSummaries.filter({ $0.id == sessionId }).count > 1,
                      let lastIdx = allSessionSummaries.lastIndex(where: { $0.id == sessionId })
                {
                    allSessionSummaries.remove(at: lastIdx)
                }
                if let index = allSessionSummaries.firstIndex(where: { $0.id == sessionId }) {
                    allSessionSummaries[index] = summary
                } else {
                    allSessionSummaries.insert(summary, at: 0)
                }
            }
            threadStore.upsert(summary)

            // Update the on-device semantic index. Skipped while streaming so
            // we only embed a thread once it has settled.
            let snapshot = session
            Task.detached(priority: .utility) { [searchService] in
                await searchService.indexThread(snapshot)
            }
        }

        // Update the project's lastSessionId
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].lastSessionId = sessionId
            do {
                try await persistence.saveProjects(projects)
            } catch {
                logger.error("Failed to save projects: \(error.localizedDescription)")
            }
        }
    }

    private func saveDraft(in window: WindowState) {
        let key = draftKey(for: window)
        let trimmed = window.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { window.draftTexts.removeValue(forKey: key) }
        else { window.draftTexts[key] = window.inputText }
    }

    private func saveQueue(in window: WindowState) {
        let key = queueKey(for: window)
        if window.messageQueue.isEmpty { window.draftQueues.removeValue(forKey: key) }
        else { window.draftQueues[key] = window.messageQueue }
    }

    /// Persistence key used for both the in-memory `draftQueues` mirror and the
    /// SwiftData `QueuedMessageRecord.sessionKey` column.
    private func queueKey(for window: WindowState) -> String {
        draftKey(for: window)
    }

    private func draftKey(for window: WindowState) -> String {
        window.currentSessionId ?? newDraftKey(for: window)
    }

    private func newDraftKey(for window: WindowState) -> String {
        guard let projectId = window.selectedProject?.id else { return "new" }
        return "new:\(projectId.uuidString)"
    }

    private func renameDraftState(from oldKey: String, to newKey: String, in window: WindowState) {
        guard oldKey != newKey else { return }

        if let text = window.draftTexts.removeValue(forKey: oldKey),
           window.draftTexts[newKey] == nil {
            window.draftTexts[newKey] = text
        }

        guard let queue = window.draftQueues.removeValue(forKey: oldKey) else { return }
        if var existing = window.draftQueues[newKey] {
            existing.append(contentsOf: queue)
            window.draftQueues[newKey] = existing
        } else {
            window.draftQueues[newKey] = queue
        }
    }

    // MARK: - Message Queue (persisted)

    func enqueueMessage(text: String, attachments: [Attachment], in window: WindowState) {
        let message = QueuedMessage(text: text, attachments: attachments)
        window.messageQueue.append(message)
        let key = queueKey(for: window)
        window.draftQueues[key] = window.messageQueue
        threadStore.appendQueued(sessionKey: key, message: message)
        broadcastMobileSessionStatus(sessionID: key)
    }

    func removeQueuedMessage(id: UUID, in window: WindowState) {
        window.dequeueMessage(id: id)
        saveQueue(in: window)
        threadStore.removeQueued(id: id)
        broadcastMobileSessionStatus(sessionID: queueKey(for: window))
    }

    /// Pops the head of the queue (the auto-flush path used when a stream ends)
    /// and removes the persisted row.
    func dequeueNextForFlush(in window: WindowState) -> QueuedMessage? {
        guard let next = window.dequeueNext() else { return nil }
        saveQueue(in: window)
        threadStore.removeQueued(id: next.id)
        broadcastMobileSessionStatus(sessionID: queueKey(for: window))
        return next
    }

    /// Cancels any in-flight stream for the current session, removes the chosen
    /// queued message, and sends it as the next user turn.
    func sendQueuedNow(id: UUID, in window: WindowState) async {
        guard let target = window.messageQueue.first(where: { $0.id == id }) else { return }
        // Take a snapshot of remaining queue items so we can restore them after
        // `cancelStreaming` clobbers `window.inputText`/`window.attachments`.
        let remaining = window.messageQueue.filter { $0.id != id }
        let draftText = window.inputText
        let draftAttachments = window.attachments
        let shouldRestoreDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty

        // Clear the queue from memory + disk first, so the cancellation path
        // doesn't see the queued item we're about to send.
        let key = queueKey(for: window)
        window.messageQueue.removeAll()
        window.draftQueues.removeValue(forKey: key)
        threadStore.clearQueue(sessionKey: key)

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        // Restore the remaining items into memory + disk.
        for msg in remaining {
            window.messageQueue.append(msg)
            threadStore.appendQueued(sessionKey: key, message: msg)
        }
        if remaining.isEmpty {
            window.draftQueues.removeValue(forKey: key)
        } else {
            window.draftQueues[key] = window.messageQueue
        }

        window.inputText = target.text
        window.attachments = target.attachments
        await send(in: window)
        if shouldRestoreDraft {
            window.inputText = draftText
            window.attachments = draftAttachments
        }
        broadcastMobileSessionStatus(sessionID: key)
    }

    /// Concatenates every queued message (texts joined with a blank line,
    /// attachments merged in order), cancels any in-flight stream, clears the
    /// queue, then sends the combined message as a single user turn.
    func sendAllQueuedAsOne(in window: WindowState) async {
        guard !window.messageQueue.isEmpty else { return }
        let snapshot = window.messageQueue
        let draftText = window.inputText
        let draftAttachments = window.attachments
        let shouldRestoreDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty

        let key = queueKey(for: window)
        window.messageQueue.removeAll()
        window.draftQueues.removeValue(forKey: key)
        threadStore.clearQueue(sessionKey: key)

        if isStreaming(in: window) {
            await cancelStreaming(in: window)
        }

        let combinedText = snapshot
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let combinedAttachments = snapshot.flatMap(\.attachments)

        window.inputText = combinedText
        window.attachments = combinedAttachments
        await send(in: window)
        if shouldRestoreDraft {
            window.inputText = draftText
            window.attachments = draftAttachments
        }
        broadcastMobileSessionStatus(sessionID: key)
    }

    /// Sends the next queued message for a background session (one the window is not currently displaying).
    /// Foreground session queues are handled by InputBarView via the isStreaming onChange handler.
    private func processBackgroundQueue(
        for sessionKey: String,
        projectId: UUID,
        cwd: String,
        in window: WindowState
    ) async {
        guard sessionStates[sessionKey]?.isStreaming != true else { return }
        guard var queue = window.draftQueues[sessionKey], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if queue.isEmpty { window.draftQueues.removeValue(forKey: sessionKey) }
        else { window.draftQueues[sessionKey] = queue }
        threadStore.removeQueued(id: next.id)

        let (resolvedAttachments, tempFilePaths) = AttachmentFactory.resolvingClipboardImages(next.attachments)
        let prompt = buildPromptWithAttachments(next.text, attachments: resolvedAttachments)
        let displayText = next.text
        let streamId = UUID()

        updateState(sessionKey) { state in
            state.messages.append(ChatMessage(role: .user, content: displayText, attachments: resolvedAttachments))
            state.inFlightUserAttachments = resolvedAttachments
            state.isStreaming = true
            state.hasUncheckedCompletion = false
            state.activeStreamId = streamId
            state.streamingStartDate = Date()
            state.currentTurnOutputTokensByMessage.removeAll(keepingCapacity: true)
            state.currentTurnOutputTokensUnkeyed = 0
        }

        let currentPermissionMode = sessionStates[sessionKey]?.permissionMode ?? permissionMode
        let projectSelection = defaultModelSelection(for: projects.first { $0.id == projectId })
        let agentProvider = sessionStates[sessionKey]?.agentProvider ?? projectSelection.provider
        var hookSettingsPath: String?
        if agentProvider == .claudeCode, !currentPermissionMode.skipsHookPipeline {
            do { hookSettingsPath = try await permission.writeHookSettingsFile() }
            catch { logger.error("Failed to write hook settings for background queue: \(error.localizedDescription)") }
        }

        await permission.registerSession(sid: sessionKey, projectKey: cwd, mode: currentPermissionMode)

        let model = sessionStates[sessionKey]?.model ?? projectSelection.model
        let effort = sessionStates[sessionKey]?.effort ?? (selectedEffort == "auto" ? nil : selectedEffort)
        let task = Task { [weak self, window] in
            guard let self else { return }
            await self.processStream(
                streamId: streamId,
                prompt: prompt,
                cwd: cwd,
                cliSessionId: sessionKey,
                internalSessionKey: sessionKey,
                agentProvider: agentProvider,
                model: model,
                effort: effort,
                hookSettingsPath: hookSettingsPath,
                permissionMode: currentPermissionMode,
                projectId: projectId,
                window: window
            )
            for path in tempFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        sessionStates[sessionKey]?.streamTask = task
    }

    private func handleError(_ error: Error, in window: WindowState) {
        logger.error("AppState error: \(error.localizedDescription)")
        addErrorMessage(error.localizedDescription, in: window)
    }

    private func addErrorMessage(_ text: String, in window: WindowState) {
        let key = window.currentSessionId ?? window.newSessionKey
        let msg = ChatMessage(role: .assistant, content: text, isError: true)
        updateState(key) { $0.messages.append(msg) }
    }

    // MARK: - Claude Settings Reader

    private nonisolated static func readPermissionModeFromSettings() -> PermissionMode {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let permissions = json["permissions"] as? [String: Any],
           let mode = permissions["defaultMode"] as? String,
           let parsed = PermissionMode(rawValue: mode)
        {
            return parsed
        }
        if let saved = UserDefaults.standard.string(forKey: "selectedPermissionMode"),
           let parsed = PermissionMode(rawValue: saved)
        {
            return parsed
        }
        return .default
    }
}

// MARK: - App Errors

private enum AppError: LocalizedError {
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
