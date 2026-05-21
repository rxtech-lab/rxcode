import SwiftUI
import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync
import TipKit

/// How the relay server is chosen in the Mobile settings tab.
private enum RelayMode: Hashable {
    /// One of the RxLab-hosted relays from the published catalog.
    case hosted
    /// A free-form relay URL typed by the user (e.g. a self-hosted relay).
    case custom
}

/// "Mobile" tab in SettingsView. Lists paired iOS / iPadOS devices and lets
/// the user pair a new one via QR code or unpair existing devices.
struct MobileSettingsTab: View {
    @StateObject private var sync = MobileSyncService.shared
    @State private var catalog = RelayPresetCatalog.shared
    @State private var showPairingSheet = false
    @State private var relayMode: RelayMode
    @State private var selectedPresetID: String?
    @State private var customURLText: String
    @State private var testNotificationDeviceID: String?
    @State private var testNotificationAlert: TestNotificationAlert?
    @State private var deviceBeingRenamed: PairedDevice?
    @State private var renameText: String = ""

    init() {
        let current = MobileSyncService.shared.relayURL
        let match = RelayPresetCatalog.bundledPresets.first {
            MobileSettingsTab.normalize($0.url) == MobileSettingsTab.normalize(current.absoluteString)
        }
        _customURLText = State(initialValue: current.absoluteString)
        if let match {
            _relayMode = State(initialValue: .hosted)
            _selectedPresetID = State(initialValue: match.id)
        } else {
            _relayMode = State(initialValue: .custom)
            let fallback = RelayPresetCatalog.bundledPresets.first { $0.recommended == true }
                ?? RelayPresetCatalog.bundledPresets.first
            _selectedPresetID = State(initialValue: fallback?.id)
        }
    }

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
        .task {
            await catalog.refresh()
            reconcileWithCatalog()
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingSheet(sync: sync)
        }
        .alert(item: $testNotificationAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "Rename Device",
            isPresented: Binding(
                get: { deviceBeingRenamed != nil },
                set: { if !$0 { deviceBeingRenamed = nil } }
            )
        ) {
            TextField("Device name", text: $renameText)
            Button("Cancel", role: .cancel) {
                deviceBeingRenamed = nil
            }
            Button("Save") {
                if let device = deviceBeingRenamed {
                    sync.renameDevice(device, to: renameText)
                }
                deviceBeingRenamed = nil
            }
        } message: {
            Text("Enter a new name for this device.")
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Relay server")
                .font(.headline)
            Text("All sync traffic flows through this relay, end-to-end encrypted. Use an RxLab-hosted relay, or point RxCode at your own — self-host with github.com/rxlab/rxcode-relay.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Relay mode", selection: $relayMode) {
                Text("Hosted server").tag(RelayMode.hosted)
                Text("Custom URL").tag(RelayMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch relayMode {
            case .hosted:
                hostedRelayPicker
            case .custom:
                customRelayField
            }

            HStack(spacing: 10) {
                Button("Apply", action: applyRelay)
                    .disabled(!canApply)
                if relayMode == .hosted, catalog.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            connectionBadge
        }
    }

    @ViewBuilder
    private var hostedRelayPicker: some View {
        if catalog.presets.isEmpty {
            Text("No hosted relays are available right now. Switch to Custom URL to enter one manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Hosted relay", selection: $selectedPresetID) {
                ForEach(catalog.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()

            if let preset = selectedPreset {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.url)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let description = preset.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var customRelayField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("wss://host:port", text: $customURLText)
                .textFieldStyle(.roundedBorder)
            if !customURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               parsedCustomURL == nil {
                Text("Enter a valid ws:// or wss:// URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Relay selection helpers

    private var selectedPreset: RelayPreset? {
        catalog.presets.first { $0.id == selectedPresetID }
    }

    /// The custom URL parsed and validated as a relay endpoint, or `nil`.
    private var parsedCustomURL: URL? {
        let trimmed = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The relay URL implied by the current mode and selection.
    private var pendingRelayURL: URL? {
        switch relayMode {
        case .hosted: selectedPreset?.relayURL
        case .custom: parsedCustomURL
        }
    }

    private var canApply: Bool {
        guard let pending = pendingRelayURL else { return false }
        return Self.normalize(pending.absoluteString) != Self.normalize(sync.relayURL.absoluteString)
    }

    private func applyRelay() {
        guard let url = pendingRelayURL else { return }
        sync.updateRelay(url: url)
    }

    /// After the live catalog loads, keep a valid preset selected and upgrade a
    /// "custom" selection to the hosted picker when the active relay turns out
    /// to be a freshly published preset.
    private func reconcileWithCatalog() {
        if selectedPreset == nil {
            selectedPresetID = catalog.presets.first { $0.recommended == true }?.id
                ?? catalog.presets.first?.id
        }
        guard relayMode == .custom,
              customURLText == sync.relayURL.absoluteString,
              let match = catalog.presets.first(where: {
                  Self.normalize($0.url) == Self.normalize(sync.relayURL.absoluteString)
              })
        else { return }
        relayMode = .hosted
        selectedPresetID = match.id
    }

    /// Normalize a URL string for equality checks (lowercased, no trailing `/`).
    static func normalize(_ urlString: String) -> String {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
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
                .popoverTip(RxCodeTips.MobileConnectionTip(), arrowEdge: .top)
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
                    if let relay = device.relayDisplayName {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(relay, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            testNotificationButton(for: device)
            Button {
                renameText = device.displayName
                deviceBeingRenamed = device
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename device")
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

    @ViewBuilder
    private func testNotificationButton(for device: PairedDevice) -> some View {
        if testNotificationDeviceID == device.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Button {
                sendTestNotification(to: device)
            } label: {
                Label("Send test notification", systemImage: "bell.badge")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(device.apnsToken?.isEmpty ?? true || sync.connectionState != .connected)
            .help(testNotificationHelp(for: device))
        }
    }

    private func sendTestNotification(to device: PairedDevice) {
        testNotificationDeviceID = device.id
        Task { @MainActor in
            defer { testNotificationDeviceID = nil }
            do {
                try await sync.sendTestNotification(to: device)
                testNotificationAlert = TestNotificationAlert(
                    title: "Test notification sent",
                    message: "Check \(device.displayName) for the RxCode notification."
                )
            } catch {
                testNotificationAlert = TestNotificationAlert(
                    title: "Test notification failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func testNotificationHelp(for device: PairedDevice) -> String {
        if device.apnsToken?.isEmpty ?? true {
            return "Open RxCode Mobile on this device once so it can register for push notifications."
        }
        if sync.connectionState != .connected {
            return "Connect to the relay before sending a test notification."
        }
        return "Send a push notification to \(device.displayName)."
    }
}

private struct TestNotificationAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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
