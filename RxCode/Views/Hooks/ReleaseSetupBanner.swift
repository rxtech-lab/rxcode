import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project's repo has no release
/// workflow configured. Built by `ReleaseHook` and rendered via
/// `HookBannerHost`. The "Set up" button opens the release deep link, which
/// `RxCodeApp`/`MainView` route to a new chat seeded with the release skill.
/// Mirrors `DocsSetupBanner`.
struct ReleaseSetupBanner: View {
    let repo: String
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    /// True while the current thread *is* the release-setup chat this banner would
    /// otherwise create — either it's already marked as a release setup session,
    /// or a release setup is staged for this project (button just clicked, first
    /// turn not yet marked). Tapping "Set up" again would spawn a duplicate setup
    /// chat, so the action is disabled. Mirrors `DocsSetupBanner`.
    private var isInReleaseSetupThread: Bool {
        if let pid = windowState.selectedProject?.id, appState.pendingReleaseSetupProjectId == pid {
            return true
        }
        if let sid = windowState.currentSessionId,
           appState.isSetupSession(kind: HookSetupKind.release, sessionKey: sid) {
            return true
        }
        return false
    }

    var body: some View {
        HookBannerRow(
            icon: "tag.fill",
            message: String(localized: "Set up releases for this repository"),
            onTap: open,
            onDismiss: onDismiss,
            isActionDisabled: isInReleaseSetupThread
        )
    }

    private func open() {
        guard let url = ReleaseDeepLink.setupURL(repo: repo) else { return }
        openURL(url)
    }
}
