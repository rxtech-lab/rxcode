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

    // MARK: Secrets

    func secretEnvironments(repoFullName: String) async -> [HookChoice] {
        guard let app else { return [] }
        do {
            let envs = try await app.secrets.listEnvironments(repo: repoFullName).items
            return envs.map { HookChoice(id: $0.id, label: $0.name) }
        } catch {
            logger.error("secretEnvironments failed: \(error.localizedDescription)")
            return []
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
}
