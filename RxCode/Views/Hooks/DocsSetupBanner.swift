import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Banner shown on the new-project screen when a project's repo has no docs
/// indexed. Built by `DocsHook` and rendered via `HookBannerHost`. The "Set up"
/// button opens the docs deep link, which `RxCodeApp`/`MainView` route to a new
/// chat seeded with the docs-publishing skill. Mirrors `SecretsEnvBanner`.
struct DocsSetupBanner: View {
    let repo: String
    /// Called when the user taps the close button. The hook persists the
    /// dismissal so the banner won't reappear.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    /// True while the current thread *is* the docs-setup chat this banner would
    /// otherwise create — either it's already marked as a docs setup session, or
    /// a docs setup is staged for this project (button just clicked, first turn
    /// not yet marked). In both cases tapping "Set up" again would spawn a
    /// duplicate setup chat, so the action is disabled.
    private var isInDocsSetupThread: Bool {
        if let pid = windowState.selectedProject?.id, appState.pendingDocsSetupProjectId == pid {
            return true
        }
        if let sid = windowState.currentSessionId,
           appState.isSetupSession(kind: HookSetupKind.docs, sessionKey: sid) {
            return true
        }
        return false
    }

    var body: some View {
        HookBannerRow(
            icon: "books.vertical.fill",
            message: String(localized: "Set up documentation so it's searchable"),
            onTap: open,
            onDismiss: onDismiss,
            isActionDisabled: isInDocsSetupThread
        )
    }

    private func open() {
        guard let url = DocsDeepLink.setupURL(repo: repo) else { return }
        openURL(url)
    }
}
