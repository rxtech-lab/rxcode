import SwiftUI

/// A centered, material-backed loading indicator shown over a screen while its
/// initial data is still being fetched from the paired Mac. Autopilot screens
/// load everything over the sync channel, so the first fetch can take a moment;
/// this overlay covers that gap instead of flashing an empty list/form.
struct MobileAutopilotLoadingOverlay: View {
    var title: LocalizedStringKey = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

extension View {
    /// Overlays a loading indicator while `isLoading` is true. Gate this on the
    /// *initial* load only (typically `isLoading && collection.isEmpty`) so it
    /// doesn't cover content during pull-to-refresh.
    @ViewBuilder
    func mobileAutopilotLoadingOverlay(
        _ isLoading: Bool,
        title: LocalizedStringKey = "Loading…"
    ) -> some View {
        overlay {
            if isLoading {
                MobileAutopilotLoadingOverlay(title: title)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

/// A centered, alert-style dialog (dimmed scrim + material card) shown while an
/// action runs. Unlike `MobileAutopilotLoadingOverlay`, this keeps the screen
/// visible behind a dimming scrim — use it for *actions* (e.g. creating a PR)
/// rather than the initial data load.
struct MobileAutopilotLoadingDialog: View {
    var title: LocalizedStringKey = "Working…"
    var message: LocalizedStringKey?

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

extension View {
    /// Overlays an alert-style loading dialog (dimmed scrim + centered card)
    /// while `isLoading` is true. Use for blocking *actions* like creating a PR.
    @ViewBuilder
    func mobileAutopilotLoadingDialog(
        _ isLoading: Bool,
        title: LocalizedStringKey = "Working…",
        message: LocalizedStringKey? = nil
    ) -> some View {
        overlay {
            if isLoading {
                MobileAutopilotLoadingDialog(title: title, message: message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}
