import os
import RxCodeCore
import SwiftUI

/// Renders hook-supplied banners for a given surface + position. The host adds
/// no chrome of its own — each banner view styles itself (see `SecretsEnvBanner`).
/// Hooks publish banners through `HookController.showBanner(in:position:id:)`.
///
/// The slide-in / fade is driven by `withAnimation` in `AppStateHookController`'s
/// `showBanner`/`dismissBanner` (so the transaction wraps the state mutation);
/// each banner carries its own `.transition`, keyed by `id` so the right view
/// animates when banners are added or removed.
struct HookBannerHost: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    let surface: HookBannerSurface
    let position: HookBannerPosition

    private static let logger = Logger(subsystem: "com.claudework", category: "HookBannerHost")

    private var items: [HookBannerItem] {
        let currentProjectId = windowState.selectedProject?.id
        return (appState.hookBanners[surface] ?? []).filter { item in
            guard item.position == position else { return false }
            // A project-scoped banner only shows while its project is open;
            // an unscoped banner (projectId == nil) always shows.
            guard let owner = item.projectId else { return true }
            return owner == currentProjectId
        }
    }

    var body: some View {
        let items = items
        let _ = Self.logger.debug("[Hook] HookBannerHost body: surface=\(surface.rawValue, privacy: .public) position=\(position.rawValue, privacy: .public) matchingItems=\(items.count, privacy: .public) totalInSurface=\(appState.hookBanners[surface]?.count ?? 0, privacy: .public)")
        VStack(spacing: 8) {
            ForEach(items) { item in
                item.content
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
