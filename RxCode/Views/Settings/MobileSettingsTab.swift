import SwiftUI
import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync

/// "Mobile" tab in SettingsView. Lists paired iOS / iPadOS devices and lets
/// the user pair a new one via QR code or unpair existing devices.
struct MobileSettingsTab: View {
    @StateObject private var sync = MobileSyncService.shared
    @State private var showPairingSheet = false
    @State private var relayURLText: String = MobileSyncService.shared.relayURL.absoluteString

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                relaySection
                Divider()
                pairedSection
            }
            .padding(20)
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingSheet(sync: sync)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mobile companion")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Pair an iPhone or iPad to view threads, get notifications, and send messages to your desktop agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay server")
                .font(.headline)
            Text("All sync traffic flows through this relay, end-to-end encrypted. Set up your own at github.com/rxlab/rxcode-relay for self-hosting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("ws://host:port", text: $relayURLText)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") {
                    if let url = URL(string: relayURLText) {
                        sync.updateRelay(url: url)
                    }
                }
                .disabled(URL(string: relayURLText) == nil)
            }
            connectionBadge
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch sync.connectionState {
        case .disconnected:
            Label("Disconnected", systemImage: "circle.slash").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .reconnecting(let s):
            Label("Reconnecting in \(s)s", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
        }
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paired devices")
                    .font(.headline)
                Spacer()
                Button {
                    showPairingSheet = true
                } label: {
                    Label("Pair new device", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(sync.connectionState != .connected)
                .help(sync.connectionState == .connected ? "" : "Connect to the relay before pairing a device.")
            }

            if sync.pairedDevices.isEmpty {
                Text("No paired devices yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(sync.pairedDevices) { device in
                    pairedRow(device)
                }
            }
        }
    }

    private func pairedRow(_ device: PairedDevice) -> some View {
        HStack {
            Image(systemName: device.platform.lowercased().contains("ipad") ? "ipad" : "iphone")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    if let token = device.apnsToken, !token.isEmpty {
                        Label("Push", systemImage: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Live channel only", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lastSeen = device.lastSeen {
                        Text("• last seen \(lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                Task { await sync.unpair(device) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Pairing sheet

private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: MobileSyncService
    @State private var token: PairingToken?
    @State private var qrImage: NSImage?
    @State private var autoReloadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a new device")
                .font(.title2)
                .fontWeight(.semibold)

            if let pending = sync.pendingPairing {
                pendingView(pending)
            } else if let image = qrImage {
                qrView(image)
            } else {
                ProgressView()
                    .frame(width: 280, height: 280)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    sync.cancelPairing()
                    dismiss()
                }
                Spacer()
            }
        }
        .frame(width: 360)
        .padding(24)
        .onAppear { startPairing() }
        .onDisappear {
            autoReloadTask?.cancel()
            autoReloadTask = nil
        }
    }

    private func startPairing() {
        autoReloadTask?.cancel()
        let fresh = sync.beginPairing()
        token = fresh
        qrImage = nil
        if let qrString = try? fresh.qrString() {
            qrImage = generateQRCode(from: qrString)
        }
        scheduleAutoReload(for: fresh)
    }

    private func scheduleAutoReload(for token: PairingToken) {
        autoReloadTask = Task { @MainActor in
            let delay = max(0, token.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard sync.pendingPairing == nil else { return }
            startPairing()
        }
    }

    @ViewBuilder
    private func qrView(_ image: NSImage) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
            Text("Scan with the RxCode app on your iPhone or iPad.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let token {
                expirationLabel(for: token)
            }
            Button {
                startPairing()
            } label: {
                Label("Force reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func expirationLabel(for token: PairingToken) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(token.expiresAt.timeIntervalSince(context.date).rounded(.down))
            if remaining > 0 {
                Label(
                    String(format: "Expires in %d:%02d", remaining / 60, remaining % 60),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(remaining < 30 ? Color.red : Color.secondary)
            } else {
                Text("Expired — generating a new QR code")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func pendingView(_ pending: PairRequestPayload) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.badge.play")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("\(pending.displayName) wants to pair")
                .font(.headline)
            Text("Platform: \(pending.platform) • \(pending.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Reject", role: .destructive) {
                    sync.cancelPairing()
                    dismiss()
                }
                Button("Accept") {
                    Task {
                        await sync.acceptPendingPairing()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 240, height: 240))
    }
}
