#if os(macOS)
import Foundation
import RxCodeCore

/// Offers "Set Up CI Update" on a project's context menu so the user can wire up
/// CI auto-updates from the same serializable menu as the other autopilot
/// actions. It's a `.deepLink` (presents the CI setup sheet locally) rather than
/// a `.command`, so desktop and mobile each open their own UI.
///
/// Unlike secrets/docs/release, there is no synchronous "is watched" cache yet,
/// so the item is offered whenever the project has a linked GitHub repo; the CI
/// setup sheet handles an already-watched repo gracefully.
@MainActor
final class CIUpdateMenuHook: Hook {
    let hookID = "builtin.ciUpdateMenu"

    func onProjectContextMenu(_ payload: ProjectContextMenuPayload, controller: any HookController) -> [MenuItem] {
        items(for: payload.project)
    }

    func onThreadContextMenu(_ payload: ThreadContextMenuPayload, controller: any HookController) -> [MenuItem] {
        items(for: payload.project)
    }

    private func items(for project: Project) -> [MenuItem] {
        guard project.gitHubRepo != nil else { return [] }
        return [
            MenuItem(
                id: "\(hookID).setup.\(project.id.uuidString)",
                title: String(localized: "Set Up CI Update"),
                systemImage: "arrow.triangle.2.circlepath",
                action: .deepLink(MenuDeepLink.url(action: MenuDeepLink.ciSetup, projectId: project.id))
            )
        ]
    }
}
#endif
