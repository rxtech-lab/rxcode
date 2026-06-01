import os
import RxCodeCore
import SwiftUI

extension Color {
    /// Hook banners always use the Claude brand orange, independent of the
    /// active app theme (which may be blue/green/purple/etc.).
    static let hookBannerAccent = Color.hex(0xD97757)
}

/// Renders hook-supplied banners for a given surface + position as a *deck of
/// cards*: only the front banner is shown, with solid back cards peeking above
/// it (inset + offset upward) to hint there are more, and a pager (chevrons +
/// dots, plus horizontal swipe) beneath to move between them. The host supplies
/// the card chrome — each banner view (`HookBannerRow`) styles only its inner row.
///
/// Hooks publish banners through `HookController.showBanner(in:position:id:)`.
/// The slide-in / fade of the whole host is driven by `withAnimation` in
/// `AppStateHookController`'s `showBanner`/`dismissBanner`.
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
        if !items.isEmpty {
            HookBannerDeck(items: items)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
    }
}

/// The deck itself: tracks which banner is at the front and renders the front
/// card over peeking back cards, with a pager when more than one banner is
/// present. `index` is clamped whenever the banner set changes (e.g. when the
/// front banner is dismissed, the next one slides into place).
private struct HookBannerDeck: View {
    let items: [HookBannerItem]

    @State private var index: Int = 0

    /// Visible peeking back cards (capped) — drives the "stacked deck" depth.
    /// The pager lets you reach every banner, so this is purely a depth hint;
    /// raise the cap to surface more of the stack at a glance.
    private var backCardCount: Int { min(3, max(0, items.count - 1)) }

    var body: some View {
        let current = min(max(index, 0), items.count - 1)
        VStack(spacing: 8) {
            if items.count > 1 {
                pager(current: current)
            }
            frontCard(current: current)
                // Reserve room above the front card so the peeking back cards
                // (which draw upward as a `.background`) don't overlap the pager
                // sitting above the deck.
                .padding(.top, items.count > 1 ? CGFloat(backCardCount) * Self.backCardStep + 4 : 0)
        }
        .onChange(of: items.count) { _, newCount in
            // Keep the front index valid as banners are added/dismissed.
            if index > newCount - 1 { index = max(0, newCount - 1) }
        }
    }

    /// Vertical gap between each back card's peeking top edge.
    private static let backCardStep: CGFloat = 11

    // MARK: - Front card + depth

    private func frontCard(current: Int) -> some View {
        // Front card: inner row + card chrome, clipped to the rounded rect.
        let card = items[current].content
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .fill(ClaudeTheme.surfaceElevated.opacity(0.95))
            )
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .fill(Color.hookBannerAccent.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .strokeBorder(Color.hookBannerAccent.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
            .id(items[current].id)
            // Deck feel: the incoming card grows up out of the peeking back-stack
            // position into the front slot, while the outgoing card lifts up and
            // fades away off the top of the deck.
            .transition(.asymmetric(
                insertion: .scale(scale: 0.92, anchor: .top)
                    .combined(with: .offset(y: 14))
                    .combined(with: .opacity),
                removal: .scale(scale: 1.04, anchor: .top)
                    .combined(with: .offset(y: -12))
                    .combined(with: .opacity)
            ))

        // Peeking back cards are added *after* the clip so they aren't clipped
        // by the front card's rounded rect; they're sized to the front card and
        // nudged upward so their top edges stack above it like a real pile.
        return card
            .background(alignment: .top) { backCards }
            .contentShape(Rectangle())
            .gesture(swipeGesture(current: current))
    }

    /// Peeking cards drawn behind the front one. Each is the same size as the
    /// front card (it's a `.background`), inset horizontally and nudged upward
    /// so a solid card edge stacks above the front one for a "pile" look.
    @ViewBuilder
    private var backCards: some View {
        ZStack(alignment: .top) {
            ForEach(1 ... max(1, backCardCount), id: \.self) { depth in
                if depth <= backCardCount {
                    RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                        .fill(ClaudeTheme.surfaceElevated.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                                .fill(Color.hookBannerAccent.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                                .strokeBorder(Color.hookBannerAccent.opacity(0.3), lineWidth: 1)
                        )
                        // Deeper cards are narrower and sit higher, peeking above
                        // the front card; opacity fades them into the background.
                        .padding(.horizontal, 7 * CGFloat(depth))
                        .offset(y: -Self.backCardStep * CGFloat(depth))
                        .opacity(max(0.4, 1 - 0.22 * CGFloat(depth)))
                        // Keep the shallowest card drawn on top of the deeper ones.
                        .zIndex(-Double(depth))
                }
            }
        }
    }

    // MARK: - Pager

    private func pager(current: Int) -> some View {
        HStack(spacing: 12) {
            pagerChevron(systemName: "chevron.left", disabled: current == 0) {
                move(to: current - 1)
            }

            HStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    Circle()
                        .fill(i == current ? Color.hookBannerAccent : ClaudeTheme.textTertiary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .onTapGesture { move(to: i) }
                }
            }

            pagerChevron(systemName: "chevron.right", disabled: current == items.count - 1) {
                move(to: current + 1)
            }
        }
    }

    private func pagerChevron(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ClaudeTheme.size(11), weight: .bold))
                .foregroundStyle(disabled ? ClaudeTheme.textTertiary.opacity(0.35) : Color.hookBannerAccent)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointerCursorOnHover()
    }

    // MARK: - Navigation

    private func move(to target: Int) {
        let clamped = min(max(target, 0), items.count - 1)
        guard clamped != index else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            index = clamped
        }
    }

    private func swipeGesture(current: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -40 {
                    move(to: current + 1)
                } else if value.translation.width > 40 {
                    move(to: current - 1)
                }
            }
    }
}
