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
