import AppKit
import Foundation
import os
import RxCodeCore
import SwiftUI

/// Concrete `HookController` backed by `AppState`. This is the *only* type
/// allowed to reach into app internals on a hook's behalf; hooks themselves
/// stay decoupled from `AppState`. Holds a `weak` reference so the controller
/// never keeps the app alive (AppState → HookManager → controller → AppState).
@MainActor
final class AppStateHookController: HookController {
    private weak var app: AppState?
    private let logger = Logger(subsystem: "com.claudework", category: "HookController")

    init(app: AppState) {
        self.app = app
    }

    // MARK: Chat cards

    func insertCard(sessionKey: String, toolName: String, input: [String: JSONValue]) -> HookCardHandle {
        let toolId = UUID().uuidString
        let messageId = UUID()
        app?.updateState(sessionKey) { state in
            let toolCall = ToolCall(id: toolId, name: toolName, input: input, result: nil)
            // Synthetic hook cards are NOT part of the agent's streaming turn, so
            // they must not carry `isStreaming` — a trailing message flagged
            // streaming while the session is not makes `settledOnlyMessages` drop
            // the whole last assistant run. The "running" spinner is driven by
            // `result == nil` instead (see `ToolResultView`).
            state.messages.append(ChatMessage(
                id: messageId,
                role: .assistant,
                blocks: [.toolCall(toolCall)],
                isStreaming: false
            ))
        }
        // Persist the card immediately (in-progress) so it survives an app reload
        // even before it completes — hook cards never reach the CLI transcript,
        // so this sidecar row is the only copy. `completeCard` updates it.
        app?.threadStore.upsertHookCard(
            sessionId: sessionKey,
            toolId: toolId,
            toolName: toolName,
            input: input,
            result: nil,
            isError: false,
            isComplete: false
        )
        return HookCardHandle(toolId: toolId, messageId: messageId)
    }

    func completeCard(_ handle: HookCardHandle, sessionKey: String, result: String, isError: Bool) {
        app?.updateState(sessionKey) { state in
            // Match by message id OR tool id: after a mid-run reload the card may
            // have been rebuilt from the persisted record with a fresh message id
            // but the same tool id, and we still want completion to land live.
            guard let idx = state.messages.firstIndex(where: { message in
                message.id == handle.messageId
                    || message.blocks.contains { $0.toolCall?.id == handle.toolId }
            }) else { return }
            state.messages[idx].setToolResult(id: handle.toolId, result: result, isError: isError)
            state.messages[idx].isStreaming = false
            state.messages[idx].isResponseComplete = true
        }
        // Persist completion so the finished card (result + badge) survives a
        // reload, matching what's now shown live.
        app?.threadStore.completeHookCard(toolId: handle.toolId, result: result, isError: isError)
    }

    func persistHookStatus(sessionKey: String, toolId: String, name: String, trigger: String, output: String, isError: Bool, isComplete: Bool) {
        guard let store = app?.threadStore else { return }
        // The card was already persisted in full by `insertCard`; only update its
        // status fields so the original `toolName`/`input` (e.g. a code-review
        // card's `summary`) is preserved on disk. Fall back to an upsert with the
        // reduced legacy payload only if the card was never inserted through this
        // controller.
        if !store.completeHookCard(toolId: toolId, result: output, isError: isError, isComplete: isComplete) {
            store.upsertHookCard(
                sessionId: sessionKey,
                toolId: toolId,
                toolName: AppState.hookToolName(for: name),
                input: [
                    "name": .string(name),
                    "trigger": .string(trigger),
                ],
                result: output,
                isError: isError,
                isComplete: isComplete
            )
        }
    }

    func enabledHookProfiles(projectId: UUID, trigger: HookTrigger) async -> [HookProfile] {
        guard let app else { return [] }
        await app.ensureHookProfilesLoaded(for: projectId)
        return app.hookProfiles(for: projectId).filter { $0.enabled && $0.trigger == trigger }
    }

    // MARK: Queries

    var notificationsEnabled: Bool { app?.notificationsEnabled ?? false }
    var isAppActive: Bool { NSApp.isActive }

    func project(for id: UUID) -> Project? {
        app?.projects.first(where: { $0.id == id })
    }

    func sessionTitle(sessionId: String) -> String? {
        app?.allSessionSummaries.first(where: { $0.id == sessionId })?.title
    }

    // MARK: Thread linkage / cross-thread sends

    func threadSkipsHooks(sessionId: String) -> Bool {
        guard let app else { return false }
        if let summary = app.allSessionSummaries.first(where: { $0.id == sessionId }) {
            return summary.skipHooks
        }
        return app.threadStore.fetch(id: sessionId)?.skipHooks ?? false
    }

    func sessionEndHooksSuppressed(sessionKey: String, sessionId: String) -> Bool {
        guard let app else { return false }
        return app.sessionEndHooksSuppressed(sessionKey: sessionKey, sessionId: sessionId)
    }

    func resolveAgentModelSelection(storedModel: String?, fallbackSessionId: String) -> (provider: AgentProvider, model: String)? {
        guard let app else { return nil }

        let fallback: (provider: AgentProvider, model: String)? = {
            if let summary = app.allSessionSummaries.first(where: { $0.id == fallbackSessionId }),
               let model = summary.model {
                return (summary.agentProvider, model)
            }
            if let session = app.threadStore.fetch(id: fallbackSessionId),
               let model = session.model {
                return (session.toSummary().agentProvider, model)
            }
            return nil
        }()

        guard let trimmed = storedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return fallback
        }

        if let separator = trimmed.firstIndex(of: ":") {
            let rawProvider = String(trimmed[..<separator])
            let model = String(trimmed[trimmed.index(after: separator)...])
            if let provider = AgentProvider(rawValue: rawProvider), !model.isEmpty {
                return (provider, model)
            }
        }

        let models = app.availableAgentModelSections().flatMap(\.models)
        if let fallback,
           let match = models.first(where: { $0.provider == fallback.provider && ($0.id == trimmed || $0.key == trimmed) }) {
            return (match.provider, match.id)
        }
        if let match = models.first(where: { $0.id == trimmed || $0.key == trimmed }) {
            return (match.provider, match.id)
        }
        if trimmed.lowercased().hasPrefix("gpt-") {
            return (.codex, trimmed)
        }

        if let fallback {
            return (fallback.provider, trimmed)
        }
        let projectId = app.allSessionSummaries.first(where: { $0.id == fallbackSessionId })?.projectId
            ?? app.threadStore.fetch(id: fallbackSessionId)?.projectId
        let project = projectId.flatMap { id in app.projects.first { $0.id == id } }
        let defaultSelection = app.defaultModelSelection(for: project)
        return (defaultSelection.provider, trimmed)
    }

    func changedFilePaths(sessionId: String) -> [String] {
        guard let app else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for edit in app.threadStore.fetchFileEdits(sessionId: sessionId) where seen.insert(edit.path).inserted {
            ordered.append(edit.path)
        }
        return ordered
    }

    func firstUserPrompt(sessionId: String) -> String? {
        guard let app else { return nil }
        let messages = app.stateForSession(sessionId).messages
        for message in messages where message.role == .user {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    func threadTranscript(sessionId: String) -> String {
        guard let app else { return "" }
        let messages = app.stateForSession(sessionId).messages
        var lines: [String] = []
        for message in messages {
            switch message.role {
            case .user:
                // Skip the injected review instruction (the only user message).
                continue
            case .assistant:
                // Text only — tool calls are deliberately excluded so the review
                // result folded back onto the parent thread (and fed into any
                // fix turn) is the reviewer's prose, not a list of tool names.
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            default:
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }
        }
        return lines.joined(separator: "\n\n")
    }

    func spawnLinkedThread(
        projectId: UUID,
        parentThreadId: String,
        label: String,
        agentProvider: AgentProvider?,
        model: String?,
        prompt: String,
        timeoutSeconds: TimeInterval
    ) async -> HookLinkedThreadResult? {
        guard let app else { return nil }
        do {
            let result = try await app.sendCrossProject(
                projectId: projectId,
                threadId: nil,
                prompt: prompt,
                agentProvider: agentProvider,
                model: model,
                // Auto mode lets the reviewer run unattended, bypassing almost
                // all permission prompts so it can freely inspect the repo (read
                // files, grep, run checks). The prompt still instructs it not to
                // edit; it just isn't gated on per-tool approvals like plan mode.
                permissionMode: .auto,
                waitForResponse: true,
                timeoutSeconds: timeoutSeconds,
                parentThreadId: parentThreadId,
                threadLabel: label,
                skipHooks: true
            )
            return HookLinkedThreadResult(
                threadId: result.threadId,
                assistantText: result.assistantText,
                error: result.error
            )
        } catch {
            logger.error("spawnLinkedThread failed: \(error.localizedDescription)")
            return nil
        }
    }

    func sendThreadMessage(sessionId: String, prompt: String, setupKind: String?) {
        guard let app else { return }
        Task { [weak app] in
            _ = try? await app?.sendCrossProject(
                projectId: nil,
                threadId: sessionId,
                prompt: prompt,
                waitForResponse: false,
                setupKind: setupKind
            )
        }
    }

    func evaluateCondition(condition: String, lastAssistantText: String, model: String?, sessionId: String) async -> Bool? {
        guard let app else { return nil }
        let trimmedCondition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty condition is treated as "always send" by the caller, but guard
        // here too so we never spend a model call on nothing.
        guard !trimmedCondition.isEmpty else { return true }

        let prompt = """
        You are a gate that decides whether a follow-up automation should run for a coding chat thread. \
        Answer with exactly one word — YES or NO. No punctuation, no explanation.

        Condition to evaluate:
        \(trimmedCondition)

        The assistant's final response this turn:
        \(String(lastAssistantText.prefix(4000)))

        Does the condition hold? Reply YES or NO.
        """

        // A per-hook model override (provider-qualified) wins; otherwise the app's
        // configured summarization model is used.
        let override: (provider: AgentProvider, model: String)? = {
            guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return resolveAgentModelSelection(storedModel: trimmed, fallbackSessionId: sessionId)
        }()

        guard let raw = await app.runHookConditionCompletion(
            prompt: prompt,
            overrideSelection: override,
            fallbackSessionId: sessionId
        ) else { return nil }

        let verdict = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if verdict.hasPrefix("YES") { return true }
        if verdict.hasPrefix("NO") { return false }
        return nil
    }

    // MARK: Review debounce / cancellation

    var reviewCountdownSeconds: TimeInterval { ReviewScheduler.defaultDelaySeconds }

    func awaitReviewGate(parentSessionKey: String, delaySeconds: TimeInterval) async -> Bool {
        guard let app else { return true }
        let outcome = await app.reviewScheduler.awaitGate(parentSessionKey: parentSessionKey, delaySeconds: delaySeconds)
        return outcome == .proceed
    }

    func markReviewRunning(parentSessionKey: String) {
        app?.reviewScheduler.markRunning(parentSessionKey: parentSessionKey)
    }

    func clearReviewRunning(parentSessionKey: String) {
        app?.reviewScheduler.clearRunning(parentSessionKey: parentSessionKey)
    }

    func reviewWasStopped(parentSessionKey: String) -> Bool {
        app?.reviewScheduler.consumeStoppedWhileRunning(parentSessionKey: parentSessionKey) ?? false
    }

    func reviewCancelReason(parentSessionKey: String) -> ReviewCancelReason? {
        app?.reviewScheduler.cancelReason(parentSessionKey: parentSessionKey)
    }

    func threadHasOngoingReview(sessionId: String) -> Bool {
        app?.reviewScheduler.hasOngoingReview(parentSessionKey: sessionId) ?? false
    }

    func threadHasNewerActivity(sessionId: String) -> Bool {
        guard let app else { return false }
        let state = app.stateForSession(sessionId)
        // A new turn streaming on this thread.
        if state.isStreaming { return true }
        // Walk back to the latest *meaningful* message, skipping synthetic cards
        // inserted by hooks (hook status cards, auto-continue, the review
        // countdown). A trailing user message means a follow-up superseded the
        // completed turn; an assistant turn — whether it ended with prose or only
        // real tool calls (e.g. file edits and no closing text) — is just the
        // turn's own response, not newer activity.
        for message in state.messages.reversed() {
            switch message.role {
            case .user:
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .assistant:
                // First real assistant message reached → the completed turn's
                // response. Synthetic-only / empty rows fall through and we keep
                // looking past them.
                if Self.isMeaningfulAssistantMessage(message) { return false }
            default:
                break
            }
        }
        return false
    }

    /// Whether an assistant message carries real activity — non-empty prose or at
    /// least one non-synthetic tool call. Hook status cards, the auto-continue
    /// card, and the review-countdown card are synthetic and don't count.
    private static func isMeaningfulAssistantMessage(_ message: ChatMessage) -> Bool {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return message.blocks.compactMap { $0.toolCall }.contains { !isSyntheticToolName($0.name) }
    }

    private static func isSyntheticToolName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("hook:")
            || name == ToolCall.autoContinueToolName
            || name == ReviewCountdownCard.toolName
    }

    func setReviewPassed(_ passed: Bool, sessionId: String) {
        app?.reviewPassedBySession[sessionId] = passed
        // Persist on the thread row so the sidebar review dot survives a reload.
        app?.threadStore.setReviewPassed(sessionId: sessionId, passed: passed)
    }

    func reviewPassed(sessionId: String) -> Bool? {
        app?.reviewPassedBySession[sessionId]
    }

    func reviewRound(sessionId: String) -> Int {
        app?.reviewRoundBySession[sessionId] ?? 0
    }

    func setReviewRound(_ round: Int, sessionId: String) {
        guard let app else { return }
        if round == 0 {
            app.reviewRoundBySession[sessionId] = nil
        } else {
            app.reviewRoundBySession[sessionId] = round
        }
    }

    func lastReviewFeedback(sessionId: String) -> String? {
        app?.lastReviewFeedbackBySession[sessionId]
    }

    func setLastReviewFeedback(_ feedback: String?, sessionId: String) {
        let trimmed = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        app?.lastReviewFeedbackBySession[sessionId] = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    func repromptThreadAfterReviewFailure(feedback: String, project: Project, sessionKey: String) -> Int? {
        guard let app else { return nil }
        return app.repromptAfterReviewFailure(feedback: feedback, project: project, sessionKey: sessionKey)
    }

    func responseNotificationFallback(from responseText: String) -> String {
        app?.responseNotificationFallback(from: responseText) ?? ""
    }

    func responseNotificationSummary(responseText: String, sessionId: String) async -> String? {
        guard let app,
              let summary = app.allSessionSummaries.first(where: { $0.id == sessionId }) else { return nil }
        return await app.generateResponseNotificationSummary(responseText: responseText, summary: summary)
    }

    // MARK: Notifications

    func postResponseComplete(title: String, body: String, projectId: UUID, sessionId: String, postLocalBanner: Bool) async {
        await NotificationService.shared.postResponseComplete(
            title: title, body: body, projectId: projectId, sessionId: sessionId, postLocalBanner: postLocalBanner
        )
    }

    func postQuestionNeeded(projectName: String?, projectId: UUID?, sessionId: String?) async {
        await NotificationService.shared.postQuestionNeeded(projectName: projectName, projectId: projectId, sessionId: sessionId)
    }

    func postPermissionNeeded(toolName: String, projectName: String?, projectId: UUID?, sessionId: String?) async {
        await NotificationService.shared.postPermissionNeeded(toolName: toolName, projectName: projectName, projectId: projectId, sessionId: sessionId)
    }

    func postMCPDisconnected(name: String, error: String?) async {
        await NotificationService.shared.postMCPDisconnected(name: name, error: error)
    }

    func postCIFailed(projectName: String?, projectId: UUID?, failingWorkflowNames: [String]) async {
        await NotificationService.shared.postCIFailed(projectName: projectName, projectId: projectId, failingWorkflowNames: failingWorkflowNames)
    }

    func postRemoteConfigChanged(title: String, body: String) async {
        await NotificationService.shared.postRemoteConfigChanged(title: title, body: body)
    }

    // MARK: Interactive UI

    func beginProgress(_ status: LocalizedStringKey) {
        app?.hookProgressStatus = status
    }

    func updateProgress(_ status: LocalizedStringKey) {
        app?.hookProgressStatus = status
    }

    func endProgress() {
        app?.hookProgressStatus = nil
    }

    func requestChoice(title: LocalizedStringKey, choices: [HookChoice]) async -> String? {
        guard let app else { return nil }
        return await withCheckedContinuation { cont in
            app.hookChoiceRequest = HookChoiceRequest(title: title, choices: choices, cont: cont)
        }
    }

    func requestConfirmation(title: LocalizedStringKey, detail: String?) async -> Bool {
        guard let app else { return false }
        return await withCheckedContinuation { cont in
            app.hookConfirmRequest = HookConfirmRequest(title: title, detail: detail, cont: cont)
        }
    }

    // MARK: Banners

    func showBanner(_ content: AnyView, id: String, projectId: UUID?, in surface: HookBannerSurface, position: HookBannerPosition) {
        guard let app else {
            logger.debug("[Hook] showBanner(\(id, privacy: .public)): app is nil — dropped")
            return
        }
        let item = HookBannerItem(id: id, position: position, projectId: projectId, content: content)
        var items = app.hookBanners[surface] ?? []
        let isNew = !items.contains { $0.id == id }
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        // Animate only when a banner actually appears, so replacing an existing
        // banner's content doesn't re-run the slide-in transition.
        if isNew {
            withAnimation(.snappy(duration: 0.28)) { app.hookBanners[surface] = items }
        } else {
            app.hookBanners[surface] = items
        }
        logger.debug("[Hook] showBanner: id=\(id, privacy: .public) surface=\(surface.rawValue, privacy: .public) position=\(position.rawValue, privacy: .public) new=\(isNew, privacy: .public) — now \(items.count, privacy: .public) banner(s) in surface")
    }

    func dismissBanner(id: String, in surface: HookBannerSurface) {
        guard let app else { return }
        guard var items = app.hookBanners[surface] else {
            logger.debug("[Hook] dismissBanner: id=\(id, privacy: .public) surface=\(surface.rawValue, privacy: .public) — no banners in surface, no-op")
            return
        }
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else {
            let present = items.map(\.id).joined(separator: ",")
            logger.debug("[Hook] dismissBanner: id=\(id, privacy: .public) surface=\(surface.rawValue, privacy: .public) — id not found, no-op. present=[\(present, privacy: .public)]")
            return
        }
        withAnimation(.snappy(duration: 0.28)) { app.hookBanners[surface] = items }
        logger.debug("[Hook] dismissBanner: id=\(id, privacy: .public) surface=\(surface.rawValue, privacy: .public) — \(before, privacy: .public)→\(items.count, privacy: .public) banner(s)")
    }

    /// UserDefaults key holding the array of banner ids the user has dismissed.
    private static let dismissedBannersKey = "hook.dismissedBanners"

    private var dismissedBannerIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedBannersKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.dismissedBannersKey) }
    }

    func isBannerDismissed(id: String) -> Bool {
        dismissedBannerIDs.contains(id)
    }

    func markBannerDismissed(id: String, in surface: HookBannerSurface) {
        var ids = dismissedBannerIDs
        ids.insert(id)
        dismissedBannerIDs = ids
        logger.debug("[Hook] markBannerDismissed: id=\(id, privacy: .public) — persisted (\(ids.count, privacy: .public) total dismissed)")
        dismissBanner(id: id, in: surface)
    }

    func clearBannerDismissal(id: String) {
        var ids = dismissedBannerIDs
        guard ids.remove(id) != nil else { return }
        dismissedBannerIDs = ids
        logger.debug("[Hook] clearBannerDismissal: id=\(id, privacy: .public) — forgotten (\(ids.count, privacy: .public) remain)")
    }

    // MARK: Secrets

    func secretEnvironments(repoFullName: String) async -> [HookChoice]? {
        guard let app else { return nil }
        do {
            let envs = try await app.secrets.listEnvironments(repo: repoFullName).items
            return envs.map { HookChoice(id: $0.id, label: $0.name) }
        } catch let SecretsService.ServiceError.apiError(status, _) where status == 404 {
            // A 404 means the repo simply isn't registered for secrets yet — a
            // definitive "no environments" answer, not a failed check. Return []
            // (not nil) so callers surface the "set up secrets" banner.
            logger.debug("secretEnvironments: repo \(repoFullName, privacy: .public) not registered (404) — treating as no environments")
            return []
        } catch {
            // nil (not []) so callers don't mistake a failed/cancelled check for
            // a repo that genuinely has no environments and show a stale banner.
            logger.error("secretEnvironments failed: \(error.localizedDescription)")
            return nil
        }
    }

    func secretFileExists(repoFullName: String, filename: String) async -> Bool {
        guard let app else { return true }
        do {
            let result = try await app.secrets.searchFiles(repo: repoFullName, filenames: [filename])
            return result.items.first(where: { $0.filename == filename })?.exists ?? false
        } catch {
            // Don't nag when the check itself fails (offline, signed-out, etc.).
            logger.error("secretFileExists failed: \(error.localizedDescription)")
            return true
        }
    }

    func fetchSecrets(repoFullName: String, env: String) async throws -> [HookSecretFile] {
        guard let app else { return [] }
        let bundle = try await app.secrets.bundle(repo: repoFullName, env: env)
        let files = try await app.decryptSecretBundle(bundle)
        return files.map { HookSecretFile(filename: $0.filename, content: $0.content) }
    }

    func writeSecrets(_ files: [HookSecretFile], toPath path: String, overwrite: Bool) throws -> [String] {
        guard let app else { return [] }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        return try app.writeDecryptedSecrets(
            files.map { (filename: $0.filename, content: $0.content) },
            to: directory,
            overwrite: overwrite
        )
    }

    // MARK: CI auto-update

    func ciRepoIsWatched(repoFullName: String) async -> Bool? {
        guard let app else { return nil }
        do {
            let statuses = try await app.ciUpdates.statuses(forRepos: [repoFullName])
            // nil (not false) only on a failed/cancelled check — a successful
            // lookup that finds no row legitimately means "not watched".
            return statuses.first(where: { $0.repositoryFullName.lowercased() == repoFullName.lowercased() })?.isWatched ?? false
        } catch {
            logger.error("ciRepoIsWatched failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Docs

    func docsIndexed(repoFullName: String) async -> Bool? {
        guard let app else { return nil }
        do {
            let statuses = try await app.docs.statuses(forRepos: [repoFullName])
            guard let s = statuses.first(where: { $0.repository.lowercased() == repoFullName.lowercased() }) else {
                logger.debug("[Hook] docsIndexed(\(repoFullName, privacy: .public)): no matching status row in \(statuses.count, privacy: .public) result(s) → treating as not set up")
                return false
            }
            // nil (not false) only on a failed/cancelled check — a successful
            // lookup that finds no row legitimately means "no docs".
            //
            // Gate on registration (`docsRepositoryId != nil`), not `hasDocs`: once
            // the repo is registered with the docs service we should stop prompting
            // setup. `hasDocs` additionally requires documents to be uploaded AND
            // embedded, which only lands after the docs-publishing CI runs (i.e.
            // after the workflow PR merges to the default branch) — so it stays
            // false for a freshly set-up repo and would keep the banner up even
            // though setup is effectively done.
            let registered = s.docsRepositoryId != nil
            logger.debug("[Hook] docsIndexed(\(repoFullName, privacy: .public)): registered=\(registered, privacy: .public) hasDocs=\(s.hasDocs, privacy: .public) documentsCount=\(s.documentsCount ?? -1, privacy: .public) readyCount=\(s.readyCount ?? -1, privacy: .public) docsRepositoryId=\(s.docsRepositoryId ?? "nil", privacy: .public)")
            return registered
        } catch {
            logger.error("docsIndexed failed: \(error.localizedDescription)")
            return nil
        }
    }

    func consumePendingDocsSetupSkill(projectId: UUID) -> String? {
        guard let app, app.pendingDocsSetupProjectId == projectId else { return nil }
        app.pendingDocsSetupProjectId = nil
        return DocsSkill.systemPrompt
    }

    // MARK: Release

    func releaseConfigured(repoFullName: String) async -> Bool? {
        guard let app else { return nil }
        do {
            let statuses = try await app.release.statuses(forRepos: [repoFullName])
            if let s = statuses.first(where: { $0.fullName.lowercased() == repoFullName.lowercased() }) {
                logger.debug("[Hook] releaseConfigured(\(repoFullName, privacy: .public)): isManaged=\(s.isManaged, privacy: .public) hasReleaseWorkflow=\(s.hasReleaseWorkflow, privacy: .public) latestVersion=\(s.latestVersion ?? "nil", privacy: .public)")
            } else {
                logger.debug("[Hook] releaseConfigured(\(repoFullName, privacy: .public)): no matching status row in \(statuses.count, privacy: .public) result(s) → treating as not managed")
            }
            // nil (not false) only on a failed/cancelled check — a successful
            // lookup that finds no row legitimately means "not set up".
            //
            // Gate on `isManaged`, not `hasReleaseWorkflow`: once the repo is
            // registered with the release service we should stop prompting setup.
            // `hasReleaseWorkflow` additionally requires a *selected dispatchable*
            // workflow, which only lands after the release workflow PR merges into
            // the default branch — so it stays false for a freshly set-up repo and
            // would keep the banner up even though setup is effectively done.
            return statuses.first(where: { $0.fullName.lowercased() == repoFullName.lowercased() })?.isManaged ?? false
        } catch {
            logger.error("releaseConfigured failed: \(error.localizedDescription)")
            return nil
        }
    }

    func consumePendingReleaseSetupSkill(projectId: UUID) -> String? {
        guard let app, app.pendingReleaseSetupProjectId == projectId else { return nil }
        app.pendingReleaseSetupProjectId = nil
        return ReleaseSkill.systemPrompt
    }

    // MARK: Context menu actions

    func projectHasSecrets(_ project: Project) -> Bool {
        app?.projectHasSecrets(project) ?? false
    }

    func projectHasDocs(_ project: Project) -> Bool {
        app?.projectHasDocs(project) ?? false
    }

    func projectHasReleaseWorkflow(_ project: Project) -> Bool {
        app?.projectHasReleaseWorkflow(project) ?? false
    }

    func projectHasCIUpdates(_ project: Project) -> Bool {
        app?.projectHasCIUpdates(project) ?? false
    }

    func projectHasUncommittedChanges(_ project: Project) -> Bool {
        // Default to visible when status is unknown (mirrors the inline menu).
        app?.projectHasUncommittedChanges(project.id) ?? true
    }

    func projectHasOpenPullRequest(_ project: Project, branch: String?) -> Bool {
        guard let app, project.gitHubRepo != nil else { return false }
        // For a branch-scoped menu (e.g. a briefing card), check that branch's
        // PR status from the branch-keyed map; otherwise use the project's
        // current-branch status. Only an *open* PR should hide "Create Pull
        // Request" — a closed/merged PR shouldn't.
        let status = branch.map { app.ciStatus(forProjectId: project.id, branch: $0) }
            ?? app.ciStatusByProject[project.id]
        return status?.pullRequestState == .open
    }

    func projectCIIsFailing(_ project: Project, branch: String?) -> Bool {
        guard let app, project.gitHubRepo != nil else { return false }
        // Branch-scoped menu (e.g. a briefing card) checks that branch's CI from
        // the branch-keyed map; a generic project menu uses the current-branch
        // status. Only an outright failure offers the fix item.
        let status = branch.map { app.ciStatus(forProjectId: project.id, branch: $0) }
            ?? app.ciStatusByProject[project.id]
        return status?.overallState == .failure
    }

    func threadHasFileChanges(sessionId: String) -> Bool {
        app?.threadHasFileChanges(sessionId: sessionId) ?? false
    }

    func customMenuItems(projectId: UUID?, surface: CustomMenuItemRecord.Surface) -> [CustomMenuItemRecord] {
        app?.threadStore.customMenuItems(projectId: projectId, surface: surface) ?? []
    }

    func requestSecretsSetup(project: Project) {
        app?.secretsSetupRequest = SecretsSetupRequest(
            repoFullName: project.gitHubRepo,
            projectPath: project.path,
            filename: nil
        )
    }

    func requestSecretsDownload(project: Project) {
        app?.secretsDownloadRequest = project
    }

    func requestDocsSetup(project: Project) {
        app?.docsSetupRequest = DocsSetupRequest(projectId: project.id, repoFullName: project.gitHubRepo)
    }

    func requestDocsSearch(project: Project) {
        app?.docsSearchRequest = UUID()
    }

    func requestReleaseSetup(project: Project) {
        app?.releaseSetupRequest = ReleaseSetupRequest(projectId: project.id, repoFullName: project.gitHubRepo)
    }

    func requestReleaseCreate(project: Project) {
        app?.releaseCreateRequest = project
    }

    func requestCISetup(project: Project) {
        app?.ciSetupRequest = CISetupRequest(
            repoFullName: project.gitHubRepo,
            projectPath: project.path
        )
    }

    // MARK: Setup-session tracking

    func markSetupSession(kind: String, sessionKey: String) {
        app?.setupSessionKeys[kind, default: []].insert(sessionKey)
        logger.debug("[Hook] markSetupSession: kind=\(kind, privacy: .public) sessionKey=\(sessionKey, privacy: .public)")
    }

    func isSetupSession(kind: String, sessionKey: String) -> Bool {
        guard let app else { return false }
        // Canonical, redirect-aware check lives on AppState (shared with the setup
        // banners). The CLI rotates the session id mid-life (`pending-<uuid>` →
        // real sid, and again on `compact_boundary`), so the marker stored when
        // the skill was injected won't raw-match a later turn's key.
        let matched = app.isSetupSession(kind: kind, sessionKey: sessionKey)
        if !matched, let keys = app.setupSessionKeys[kind], !keys.isEmpty {
            let target = app.resolveCurrentSessionId(sessionKey)
            logger.debug("[Hook] isSetupSession(kind=\(kind, privacy: .public)): no match. query=\(sessionKey, privacy: .public)→\(target, privacy: .public) stored=[\(keys.map { "\($0)→\(app.resolveCurrentSessionId($0))" }.joined(separator: ","), privacy: .public)]")
        }
        return matched
    }

    func clearSetupSession(kind: String, sessionKey: String) {
        guard let app, let keys = app.setupSessionKeys[kind] else { return }
        // Remove every stored key that resolves to the same canonical sid as the
        // one being cleared (mirrors the redirect-aware match in `isSetupSession`).
        let target = app.resolveCurrentSessionId(sessionKey)
        let stale = keys.filter { app.resolveCurrentSessionId($0) == target }
        app.setupSessionKeys[kind]?.subtract(stale)
    }
}
