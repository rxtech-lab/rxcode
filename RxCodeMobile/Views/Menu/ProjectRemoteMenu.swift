import RxCodeCore
import RxCodeSync
import SwiftUI

/// The on-device autopilot UI a menu deep link should open. Shared by every
/// mobile surface that renders the desktop's serialized menu so the secrets /
/// docs / release / CI setup prompts live in one place.
enum MobileMenuDeepLinkTarget {
    case secretsDownload
    case releaseCreate
    /// Open a new on-device setup chat prefilled with this prompt.
    case setupChat(String)
}

/// Map a `rxcode://menu/…` deep link to the matching on-device target, or `nil`
/// when there's no on-device equivalent (e.g. docs search is desktop-only).
func mobileMenuDeepLinkTarget(_ url: URL) -> MobileMenuDeepLinkTarget? {
    guard let parsed = MenuDeepLink.parse(url) else { return nil }
    switch parsed.action {
    case MenuDeepLink.secretsDownload:
        return .secretsDownload
    case MenuDeepLink.secretsSetup:
        return .setupChat("Set up encrypted secrets for this repository so I can sync environment files securely.")
    case MenuDeepLink.docsSetup:
        return .setupChat("Set up documentation publishing for this repository so its docs are indexed into RxCode docs search.")
    case MenuDeepLink.releaseCreate:
        return .releaseCreate
    case MenuDeepLink.releaseSetup:
        return .setupChat("Set up a release workflow for this repository (semantic-release + a GitHub Actions release workflow).")
    case MenuDeepLink.ciSetup:
        return .setupChat("Set up CI auto-update for this repository so failing CI is fixed automatically.")
    default:
        return nil // docs-search and unknown actions have no on-device sheet.
    }
}

/// Adds a project context menu backed by the desktop's serializable menu: the
/// same hook-built `[MenuItem]` the Mac renders, fetched over the relay and
/// rendered on-device. Commands run on the Mac via the shared dispatcher; deep
/// links open the matching on-device autopilot sheet / setup chat.
///
/// Because `.contextMenu` builds synchronously, the menu is prefetched into state
/// when the host appears. Reused by the project sidebar cards and the briefing
/// cards so both surfaces share one implementation.
extension View {
    /// Attach the desktop-backed project context menu. A no-op when `project` is
    /// nil (e.g. a briefing card whose project isn't resolved yet).
    ///
    /// Pass `branch` on a briefing card (which represents one branch): the menu
    /// then leads with branch-scoped Code Review / Commit All commands (carrying
    /// that branch) ahead of the project's autopilot items, mirroring the desktop
    /// briefing menu. With `branch == nil` (project list), the generic project
    /// menu is used as-is.
    @ViewBuilder
    func projectRemoteContextMenu(project: Project?, branch: String? = nil) -> some View {
        if let project {
            modifier(ProjectRemoteMenuModifier(project: project, branch: branch))
        } else {
            self
        }
    }
}

private struct ProjectRemoteMenuModifier: ViewModifier {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.openURL) private var openURL
    let project: Project
    let branch: String?

    @State private var items: [MenuItem] = []
    @State private var showingSecretsDownload = false
    @State private var showingReleaseCreate = false
    @State private var setupChat: AutopilotSetupChat?
    @State private var info: AutopilotMenuInfo?
    @State private var autopilotStatus: AutopilotProjectStatus?
    @State private var isRunning = false

    /// Re-key the prefetch on the branch and the desktop status the menu is gated
    /// by (git dirty + PR state), so the menu refreshes after commits / PR
    /// creation / status polls land in the snapshot instead of showing stale
    /// actions.
    private var refreshKey: String {
        let dirty = state.projectDirtyByProject[project.id].map(String.init) ?? "nil"
        let pr = state.ciStatusByProject[project.id]?.prNumber.map(String.init) ?? "nil"
        return "\(project.id.uuidString)|\(branch ?? "nil")|\(dirty)|\(pr)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: refreshKey) {
                // Ask the desktop for the (branch-scoped) hook-built menu and
                // render exactly what it returns — no items assembled here.
                items = (try? await state.fetchProjectMenu(projectId: project.id, branch: branch)) ?? []
            }
            .contextMenu {
                if items.isEmpty {
                    Button {} label: { Label("Loading…", systemImage: "hourglass") }
                        .disabled(true)
                } else {
                    MenuItemsView(items)
                        .menuActionHandler(handler)
                }
            }
            .projectAutopilotMenuHost(
                project: project,
                status: $autopilotStatus,
                showDownloadSheet: $showingSecretsDownload,
                showReleaseCreate: $showingReleaseCreate,
                setupChat: $setupChat,
                info: $info,
                state: state
            )
            .mobileAutopilotLoadingDialog(
                isRunning,
                title: "Working…",
                message: "The Mac is performing the requested action."
            )
    }

    private var handler: MenuActionHandler {
        MenuActionHandler { action in
            switch action {
            case .command(let command):
                run(command)
            case .deepLink(let url):
                handleDeepLink(url)
            }
        }
    }

    private func run(_ command: MenuActionCommand) {
        guard !isRunning else { return }
        // Only block behind the loading dialog for async commands; instant
        // commands (e.g. stop review) skip the scrim.
        let showsLoading = command.isAsync
        if showsLoading { isRunning = true }
        Task {
            defer { if showsLoading { isRunning = false } }
            do {
                let result = try await state.executeMenuCommand(command)
                await state.refreshSnapshot()
                if let threadId = result.threadId {
                    // Navigate into the spawned thread (sidebar → project → thread).
                    state.pendingDeepLink = MobileDeepLink(sessionID: threadId, projectID: project.id)
                }
                if let urlString = result.openURL, let url = URL(string: urlString) {
                    openURL(url)
                }
            } catch {
                info = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        switch mobileMenuDeepLinkTarget(url) {
        case .secretsDownload:
            showingSecretsDownload = true
        case .releaseCreate:
            showingReleaseCreate = true
        case .setupChat(let prompt):
            setupChat = AutopilotSetupChat(prompt: prompt)
        case nil:
            break
        }
    }
}
