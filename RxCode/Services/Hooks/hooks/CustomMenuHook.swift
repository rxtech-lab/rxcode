#if os(macOS)
import Foundation
import RxCodeCore

/// Surfaces the user's own context-menu entries (configured in Settings →
/// Context Menus) on the project, thread, and briefing-card menus. Each enabled
/// `CustomMenuItemRecord` becomes a serializable `MenuItem` carrying a
/// `.custom` command — so the desktop renders it natively and mobile fetches the
/// identical item over the relay. The work itself runs on the desktop through
/// `AppState.dispatchMenuCommand`.
///
/// Context placeholders in the request/message templates (`{{projectName}}`,
/// `{{projectPath}}`, `{{gitHubRepo}}`, `{{branch}}`, `{{sessionId}}`) are
/// substituted here at build time, where the project/branch/thread are known, so
/// the command that crosses the relay is fully resolved.
@MainActor
final class CustomMenuHook: Hook {
    let hookID = "builtin.customMenu"

    // MARK: - Project / briefing menus

    func onProjectContextMenu(_ payload: ProjectContextMenuPayload, controller: any HookController) -> [MenuItem] {
        // A branch-scoped menu is a briefing card; an unscoped one is the generic
        // project menu. Each surfaces its own configured items.
        let surface: CustomMenuItemRecord.Surface = payload.branch != nil ? .briefing : .project
        let context = PlaceholderContext(project: payload.project, branch: payload.branch, sessionId: nil)
        return controller.customMenuItems(projectId: payload.project.id, surface: surface)
            .map { item($0, surface: surface, context: context, projectId: payload.project.id) }
    }

    // MARK: - Thread menu

    func onThreadContextMenu(_ payload: ThreadContextMenuPayload, controller: any HookController) -> [MenuItem] {
        let context = PlaceholderContext(project: payload.project, branch: nil, sessionId: payload.session.id)
        return controller.customMenuItems(projectId: payload.project.id, surface: .thread)
            .map { item($0, surface: .thread, context: context, projectId: payload.project.id, sessionId: payload.session.id) }
    }

    // MARK: - Build one item

    private func item(
        _ record: CustomMenuItemRecord,
        surface: CustomMenuItemRecord.Surface,
        context: PlaceholderContext,
        projectId: UUID,
        sessionId: String? = nil
    ) -> MenuItem {
        let config = resolvedConfig(record, context: context, sessionId: sessionId)
        let isAPI = record.actionKindValue == .callAPI
        return MenuItem(
            id: "\(hookID).\(surface.rawValue).\(record.id)",
            title: record.title,
            systemImage: record.systemImage,
            action: .command(MenuActionCommand(
                kind: .custom,
                projectId: projectId,
                sessionId: sessionId,
                branch: context.branch,
                isAsync: isAPI,
                custom: config
            ))
        )
    }

    /// Resolve a record's templated fields into a concrete `CustomMenuActionConfig`.
    private func resolvedConfig(
        _ record: CustomMenuItemRecord,
        context: PlaceholderContext,
        sessionId: String?
    ) -> CustomMenuActionConfig {
        switch record.actionKindValue {
        case .callAPI:
            let headers = record.headers.reduce(into: [String: String]()) { acc, pair in
                acc[pair.key] = context.substitute(pair.value)
            }
            return CustomMenuActionConfig(
                kind: .callAPI,
                httpMethod: record.httpMethod ?? "GET",
                url: context.substitute(record.urlString),
                headers: headers.isEmpty ? nil : headers,
                body: context.substitute(record.bodyTemplate)
            )
        case .createThread:
            return CustomMenuActionConfig(
                kind: .createThread,
                message: context.substitute(record.messageTemplate)
            )
        case .continueThread:
            // An explicit target wins (with placeholders like {{sessionId}}
            // resolved); otherwise fall back to the tapped thread.
            let resolvedTarget = context.substitute(record.targetSessionId)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CustomMenuActionConfig(
                kind: .continueThread,
                message: context.substitute(record.messageTemplate),
                targetSessionId: (resolvedTarget?.isEmpty == false) ? resolvedTarget : sessionId
            )
        }
    }
}

/// The values available for `{{…}}` placeholder substitution in custom menu
/// templates, captured from the menu's context at build time.
private struct PlaceholderContext {
    let project: Project
    let branch: String?
    let sessionId: String?

    /// Replace every known token in `template`. Returns nil for a nil input.
    func substitute(_ template: String?) -> String? {
        guard let template, !template.isEmpty else { return template }
        var out = template
        let replacements: [String: String] = [
            "{{projectName}}": project.name,
            "{{projectPath}}": project.path,
            "{{gitHubRepo}}": project.gitHubRepo ?? "",
            "{{branch}}": branch ?? "",
            "{{sessionId}}": sessionId ?? ""
        ]
        for (token, value) in replacements {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}
#endif
