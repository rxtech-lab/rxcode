import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

// MARK: - Pairing sheet

struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: MobileSyncService
    @State private var token: PairingToken?
    @State private var qrImage: NSImage?
    @State private var autoReloadTask: Task<Void, Never>?
    @State private var selectedServerID: UUID?

    init(sync: MobileSyncService, catalog: RelayPresetCatalog) {
        self.sync = sync
        // Select first connected server by default
        let firstConnected = sync.savedRelayServers.first { server in
            sync.relayConnectionStates[server.id] == .connected
        }
        self._selectedServerID = State(initialValue: firstConnected?.id ?? sync.savedRelayServers.first?.id)
    }

    /// Only show servers that are connected.
    private var connectedServers: [SavedRelayServer] {
        sync.savedRelayServers.filter { server in
            sync.relayConnectionStates[server.id] == .connected
        }
    }

    private var selectedServer: SavedRelayServer? {
        sync.savedRelayServers.first { $0.id == selectedServerID }
    }

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
        .frame(width: 400)
        .padding(24)
        .onAppear { startPairing() }
        .onDisappear {
            autoReloadTask?.cancel()
            autoReloadTask = nil
        }
        .onChange(of: selectedServerID) { _, _ in
            startPairing()
        }
    }

    private func startPairing() {
        autoReloadTask?.cancel()
        guard let server = selectedServer,
              let fresh = sync.beginPairing(viaServer: server)
        else {
            token = nil
            qrImage = nil
            return
        }
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
        VStack(spacing: 12) {
            // Relay server picker (only connected servers)
            if connectedServers.count > 1 {
                HStack {
                    Text("Relay:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Relay server", selection: $selectedServerID) {
                        ForEach(connectedServers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            } else if let server = selectedServer {
                HStack(spacing: 4) {
                    Text("Via:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(server.name)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }

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
                Label("Regenerate", systemImage: "arrow.clockwise")
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
                .foregroundStyle(remaining < 30 ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
            } else {
                Text("Expired — generating a new QR code")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.statusError)
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
