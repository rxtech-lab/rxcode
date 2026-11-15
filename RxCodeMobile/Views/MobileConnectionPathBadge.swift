import SwiftUI

/// Compact pill showing whether the phone reaches the Mac over the LAN, a
/// direct internet link, or the relay. Tapping it explains the route.
struct MobileConnectionPathBadge: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var showingDetail = false

    var body: some View {
        let route = state.activeConnectionRoute
        Button {
            MobileHaptics.buttonTap()
            showingDetail = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: route.systemImage)
                    .font(.caption.weight(.semibold))
                    .symbolEffect(.rotate, isActive: route == .connecting)
                Text(route.title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Self.tint(for: route))
            .padding(.horizontal, 4)
            .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(Text("Connection: \(route.title)"))
        .accessibilityHint(Text("Shows how this device reaches your Mac"))
        .accessibilityIdentifier("connection-path-badge")
        .animation(.smooth(duration: 0.25), value: route)
        .popover(isPresented: $showingDetail) {
            MobileConnectionPathDetail(route: route, desktopName: state.activePairedDesktop?.displayName)
                .presentationCompactAdaptation(.popover)
        }
    }

    static func tint(for route: MobileConnectionRoute) -> Color {
        switch route {
        case .lan, .directInternet: .green
        case .relay: .blue
        case .connecting: .orange
        case .offline: .red
        }
    }
}

private struct MobileConnectionPathDetail: View {
    let route: MobileConnectionRoute
    let desktopName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(route.title).font(.headline)
            } icon: {
                Image(systemName: route.systemImage)
                    .foregroundStyle(MobileConnectionPathBadge.tint(for: route))
            }
            if let desktopName, !desktopName.isEmpty {
                Text(desktopName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(route.detail)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(idealWidth: 280, maxWidth: 320, alignment: .leading)
    }
}
