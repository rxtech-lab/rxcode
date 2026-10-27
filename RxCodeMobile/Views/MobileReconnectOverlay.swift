import SwiftUI

/// Non-blocking status capsule shown over the workspace while the paired Mac is
/// unreachable after the initial sync. The workspace stays mounted and usable
/// underneath, so typing and navigation are never interrupted by a reconnect.
struct MobileReconnectOverlay: View {
    var desktopName: String?
    /// The relay is up but the Mac itself did not answer (offline / asleep).
    var isUnavailable: Bool
    var isRetrying: Bool
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reconnecting…")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Retry", action: onRetry)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(isRetrying)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reconnect-overlay")
    }

    private var detail: String {
        let name = desktopName ?? String(localized: "your Mac")
        return isUnavailable
            ? String(localized: "Waiting for \(name)")
            : String(localized: "Connecting to \(name)")
    }
}

#Preview {
    MobileReconnectOverlay(desktopName: "MacBook Pro", isUnavailable: true, isRetrying: false, onRetry: {})
}
