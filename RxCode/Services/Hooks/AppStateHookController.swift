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
        return HookCardHandle(toolId: toolId, messageId: messageId)
    }

    func completeCard(_ handle: HookCardHandle, sessionKey: String, result: String, isError: Bool) {
        app?.updateState(sessionKey) { state in
            guard let idx = state.messages.firstIndex(where: { $0.id == handle.messageId }) else { return }
            state.messages[idx].setToolResult(id: handle.toolId, result: result, isError: isError)
            state.messages[idx].isStreaming = false
            state.messages[idx].isResponseComplete = true
        }
    }

    func persistHookStatus(sessionKey: String, toolId: String, name: String, trigger: String, output: String, isError: Bool) {
        app?.threadStore.setHookStatus(
            sessionId: sessionKey,
            toolId: toolId,
            name: name,
            trigger: trigger,
            output: output,
            isError: isError
        )
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
        guard var items = app.hookBanners[surface] else { return }
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
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
            // nil (not false) only on a failed/cancelled check — a successful
            // lookup that finds no row legitimately means "no docs".
            return statuses.first(where: { $0.repository.lowercased() == repoFullName.lowercased() })?.hasDocs ?? false
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
}
