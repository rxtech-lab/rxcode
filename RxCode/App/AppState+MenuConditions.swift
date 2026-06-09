#if os(macOS)
import Foundation
import os
import RxCodeCore

private let menuConditionLogger = Logger(subsystem: "com.rxlab.RxCode", category: "MenuCondition")

/// Show-condition evaluation for custom context-menu items. Menu building is
/// synchronous (SwiftUI builds context menus the instant they open), but a Swift
/// script condition has to compile and run a subprocess. So the synchronous path
/// reads `menuConditionResults`; a cache miss shows the item and triggers an async
/// evaluation that fills the cache and bumps `customMenuItemsRevision` so the next
/// menu open reflects the real result. The mobile relay path is async, so it can
/// `warmMenuConditions(...)` up front and get accurate results on the first fetch.
extension AppState {
    /// Synchronous gate used by `CustomMenuHook`. Returns whether `record` should
    /// appear, given its condition. `always` items and items without a script show
    /// unconditionally. For a `swiftScript` item: a cached result is authoritative;
    /// a miss returns `true` (show) and schedules a background evaluation.
    func shouldShowConditionalMenuItem(
        _ record: CustomMenuItemRecord,
        project: Project,
        branch: String?,
        sessionId: String?
    ) -> Bool {
        guard record.conditionTypeValue == .swiftScript,
              let script = record.conditionScript, !script.isEmpty else {
            menuConditionLogger.debug("[ContextMenuCondition] shouldShow[\(record.title, privacy: .public)]: conditionType=\(record.conditionType, privacy: .public) scriptEmpty=\((record.conditionScript ?? "").isEmpty) -> show=true (no condition)")
            return true
        }

        let key = menuConditionKey(record: record, project: project, branch: branch, sessionId: sessionId)
        if let cached = menuConditionResults[key] {
            menuConditionLogger.debug("[ContextMenuCondition] shouldShow[\(record.title, privacy: .public)]: cache HIT key=\(key, privacy: .public) -> show=\(cached, privacy: .public)")
            return cached
        }

        // Miss: show by default now, evaluate in the background, refresh on result.
        let inFlight = menuConditionInFlight.contains(key)
        menuConditionLogger.debug("[ContextMenuCondition] shouldShow[\(record.title, privacy: .public)]: cache MISS key=\(key, privacy: .public) inFlight=\(inFlight) -> show=true (default), scheduling eval")
        if !inFlight {
            menuConditionInFlight.insert(key)
            let context = menuConditionContext(project: project, branch: branch, sessionId: sessionId)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.menuConditionEvaluator.evaluate(script: script, context: context)
                self.storeMenuConditionResult(result, forKey: key)
            }
        }
        return true
    }

    /// Eagerly evaluate every conditional item for `project` on the surface implied
    /// by `branch`/`sessionId`, populating `menuConditionResults` before a
    /// (synchronous) menu build. Used by the mobile relay so the phone's first
    /// fetch already reflects the conditions.
    func warmMenuConditions(for project: Project, branch: String?, sessionId: String?) async {
        let surface: CustomMenuItemRecord.Surface = sessionId != nil
            ? .thread
            : (branch != nil ? .briefing : .project)

        let conditional = threadStore.customMenuItems(projectId: project.id, surface: surface)
            .filter { $0.conditionTypeValue == .swiftScript && !($0.conditionScript ?? "").isEmpty }
        guard !conditional.isEmpty else { return }

        let context = menuConditionContext(project: project, branch: branch, sessionId: sessionId)
        for record in conditional {
            guard let script = record.conditionScript else { continue }
            let key = menuConditionKey(record: record, project: project, branch: branch, sessionId: sessionId)
            let result = await menuConditionEvaluator.evaluate(script: script, context: context)
            menuConditionResults[key] = result
        }
    }

    // MARK: - Editor support

    /// Compile a condition script (used by the editor's Compile button). Returns
    /// whether it built and, on failure, the compiler diagnostics.
    func compileMenuConditionScript(_ script: String) async -> CustomMenuConditionEvaluator.CompileResult {
        await menuConditionEvaluator.compile(script: script)
    }

    /// Generate a condition script from a natural-language requirement using the
    /// app's default model (falling back to the Claude default when the configured
    /// default provider isn't Claude Code).
    func generateMenuConditionScript(requirement: String, project: Project?) async -> String? {
        let selection = defaultModelSelection(for: project)
        let model = selection.provider == .claudeCode ? selection.model : "default"
        return await claude.generateConditionScript(requirement: requirement, model: model)
    }

    // MARK: - Helpers

    private func menuConditionContext(
        project: Project,
        branch: String?,
        sessionId: String?
    ) -> CustomMenuConditionEvaluator.Context {
        CustomMenuConditionEvaluator.Context(
            projectName: project.name,
            projectPath: project.path,
            gitHubRepo: project.gitHubRepo ?? "",
            branch: branch ?? "",
            sessionId: sessionId ?? ""
        )
    }

    /// Cache key for one item in one context. `updatedAt` invalidates the entry
    /// when the item (and thus its script) is edited.
    private func menuConditionKey(
        record: CustomMenuItemRecord,
        project: Project,
        branch: String?,
        sessionId: String?
    ) -> String {
        "\(record.id)|\(record.updatedAt.timeIntervalSince1970)|\(project.id.uuidString)|\(branch ?? "")|\(sessionId ?? "")"
    }

    private func storeMenuConditionResult(_ result: Bool, forKey key: String) {
        menuConditionInFlight.remove(key)
        let previous = menuConditionResults[key]
        menuConditionResults[key] = result
        // Re-render the menu when the result changes what's shown. A first-time
        // `true` matches the show-by-default assumption, so it needs no refresh.
        let willRefresh = previous != result && !(previous == nil && result == true)
        menuConditionLogger.debug("[ContextMenuCondition] storeResult: key=\(key, privacy: .public) previous=\(previous.map(String.init(describing:)) ?? "nil", privacy: .public) result=\(result, privacy: .public) refresh=\(willRefresh) revision=\(self.customMenuItemsRevision)")
        if willRefresh {
            customMenuItemsRevision += 1
        }
    }
}
#endif
