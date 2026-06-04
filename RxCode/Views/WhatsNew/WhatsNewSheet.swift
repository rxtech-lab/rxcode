import RxCodeCore
import SwiftUI

/// A carousel of "What's New" feature cards, presented as a sheet the first
/// time an existing user launches a build that introduces new features.
///
/// Each card is marked as seen (by `slug`) the moment it appears, and the whole
/// presented batch is marked on dismiss — so cards never re-appear on a later
/// launch. Mirrors the onboarding card visual language.
struct WhatsNewSheet: View {
    @Environment(AppState.self) private var appState

    /// The unseen features to present. Captured once by the caller so the list
    /// does not shrink underneath us as cards are marked seen.
    let features: [WhatsNewFeature]
    var onDismiss: () -> Void

    @State private var selectedIndex = 0

    private var isLastSlide: Bool {
        selectedIndex >= features.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            cardStack
            pageIndicator
                .padding(.top, 18)
            primaryButton
                .padding(.top, 20)
                .padding(.bottom, 28)
        }
        .frame(width: 520, height: 600)
        .background(ClaudeTheme.background)
        .onAppear {
            // Defensive: an empty batch should never present, but if it does we
            // just dismiss instead of indexing into an empty array.
            if features.isEmpty { onDismiss() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text("New in RxCode")
                    .font(.system(size: ClaudeTheme.size(20), weight: .bold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .background(ClaudeTheme.surfaceSecondary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Close"))
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var cardStack: some View {
        ZStack {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                featureCard(feature)
                    .opacity(selectedIndex == index ? 1 : 0)
                    .scaleEffect(selectedIndex == index ? 1 : 0.96)
                    .offset(x: CGFloat(index - selectedIndex) * 60)
                    .allowsHitTesting(selectedIndex == index)
                    .onAppear {
                        // Mark seen as soon as the card is reachable so it never
                        // shows again, matching "viewed → read".
                        if selectedIndex == index {
                            appState.markWhatsNewSeen(feature.slug)
                        }
                    }
            }
        }
        .animation(.snappy(duration: 0.42), value: selectedIndex)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedIndex) { _, newValue in
            if features.indices.contains(newValue) {
                appState.markWhatsNewSeen(features[newValue].slug)
            }
        }
    }

    private func featureCard(_ feature: WhatsNewFeature) -> some View {
        VStack(spacing: 18) {
            iconTile(feature.icon)

            VStack(spacing: 8) {
                Text(feature.title)
                    .font(.system(size: ClaudeTheme.size(24), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(feature.subtitle)
                    .font(.system(size: ClaudeTheme.size(14)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(feature.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: highlight.icon)
                            .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                            .foregroundStyle(ClaudeTheme.accent)
                            .frame(width: 22, alignment: .center)
                        Text(highlight.text)
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous))
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func iconTile(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: ClaudeTheme.size(34), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(
                LinearGradient(
                    colors: [ClaudeTheme.accent, ClaudeTheme.accent.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
            )
            .shadow(color: ClaudeTheme.accent.opacity(0.28), radius: 14, y: 8)
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(features.indices, id: \.self) { index in
                Capsule()
                    .fill(index == selectedIndex ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary.opacity(0.36))
                    .frame(width: index == selectedIndex ? 24 : 8, height: 8)
                    .animation(.snappy(duration: 0.28), value: selectedIndex)
            }
        }
        .accessibilityHidden(true)
        .opacity(features.count > 1 ? 1 : 0)
    }

    private var primaryButton: some View {
        Button {
            advance()
        } label: {
            Text(isLastSlide ? LocalizedStringKey("Got it") : LocalizedStringKey("Next"))
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                .frame(width: 230, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(ClaudeTheme.accent, in: Capsule())
        .shadow(color: ClaudeTheme.accent.opacity(0.24), radius: 12, y: 6)
    }

    private func advance() {
        if isLastSlide {
            dismiss()
        } else {
            withAnimation(.snappy(duration: 0.42)) {
                selectedIndex += 1
            }
        }
    }

    private func dismiss() {
        // Mark the entire presented batch as seen so nothing re-appears even if
        // the user closed before paging through every card.
        appState.markWhatsNewSeen(features.map(\.slug))
        onDismiss()
    }
}

#Preview {
    WhatsNewSheet(features: WhatsNewFeature.all) {}
        .environment(AppState())
}
