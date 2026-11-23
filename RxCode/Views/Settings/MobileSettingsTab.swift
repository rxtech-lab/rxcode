import CoreImage.CIFilterBuiltins
import RxCodeCore
import RxCodeSync
import SwiftUI
import TipKit

/// "Mobile" tab in SettingsView. Lists paired iOS / iPadOS devices and lets
/// the user pair a new one via QR code or unpair existing devices.
struct MobileSettingsTab: View {
    @StateObject private var sync = MobileSyncService.shared
    @State private var catalog = RelayPresetCatalog.shared
    @State private var showPairingSheet = false
    @State private var showAddRelaySheet = false
    @State private var testNotificationDeviceID: String?
    @State private var copiedTokenDeviceID: String?
    @State private var testNotificationAlert: TestNotificationAlert?
    @State private var deviceBeingRenamed: PairedDevice?
    @State private var renameText: String = ""
    @State private var relayToEdit: SavedRelayServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                relaySection
                directConnectionsSection
                ClaudeThemeDivider()
                pairedSection
            }
            .padding(20)
        }
        .task {
            await catalog.refresh()
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingSheet(sync: sync, catalog: catalog)
        }
        .sheet(isPresented: $showAddRelaySheet) {
            RelayServerEditorSheet(sync: sync, catalog: catalog, existingServer: nil)
        }
        .sheet(item: $relayToEdit) { server in
            RelayServerEditorSheet(sync: sync, catalog: catalog, existingServer: server)
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
            HStack {
                Text("Relay servers")
                    .font(.headline)
                Spacer()
                Button {
                    showAddRelaySheet = true
                } label: {
                    Label("Add server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .popoverTip(RxCodeTips.AddRelayServerTip(), arrowEdge: .top)
            }
            Text("All sync traffic flows through relay servers, end-to-end encrypted. Add relay servers to connect with your mobile devices remotely.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // List of relay servers with connection status
            VStack(spacing: 8) {
                ForEach(sync.savedRelayServers) { server in
                    relayServerRow(server)
                }

                if sync.savedRelayServers.isEmpty {
                    Label("No relay servers", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
            }
        }
    }

    private func relayServerRow(_ server: SavedRelayServer) -> some View {
        let connectionState = sync.relayConnectionStates[server.id] ?? .disconnected
        let isConnected = connectionState == .connected
        return HStack {
            // Connection status indicator
            connectionStatusIcon(for: connectionState)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .fontWeight(.medium)
                    if !server.isEnabled {
                        Text("Disabled")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(server.displayHost ?? server.url)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.secondary)
                    connectionStatusText(for: connectionState)
                        .font(.caption)
                }
            }
            Spacer()

            // Toggle enabled state
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { newValue in
                    var updated = server
                    updated.isEnabled = newValue
                    sync.updateRelayServer(updated)
                    if newValue {
                        Task { await sync.startRelayServer(updated) }
                    } else {
                        Task { await sync.stopRelayServer(updated) }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                relayToEdit = server
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task {
                    await sync.stopRelayServer(server)
                    sync.removeRelayServer(server)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(isConnected ? ClaudeTheme.statusSuccess.opacity(0.1) : ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func connectionStatusIcon(for state: RelayClient.ConnectionState) -> some View {
        switch state {
        case .disconnected:
            Image(systemName: "circle.slash")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        case .reconnecting:
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(ClaudeTheme.statusWarning)
        }
    }

    @ViewBuilder
    private func connectionStatusText(for state: RelayClient.ConnectionState) -> some View {
        switch state {
        case .disconnected:
            Text("Disconnected")
                .foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…")
                .foregroundStyle(ClaudeTheme.statusWarning)
        case .connected:
            Text("Connected")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        case .reconnecting(let seconds):
            Text("Reconnecting in \(seconds)s")
                .foregroundStyle(ClaudeTheme.statusWarning)
        }
    }

    /// Check if any relay server is connected.
    private var hasConnectedRelay: Bool {
        sync.relayConnectionStates.values.contains(.connected)
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
                .disabled(!hasConnectedRelay)
                .help(hasConnectedRelay ? "" : "Connect to a relay server before pairing a device.")
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
            Image(systemName: Self.deviceIconName(for: device))
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .fontWeight(.medium)
                    onlineStatePill(for: device)
                    pathPill(for: device)
                }
                HStack(spacing: 6) {
                    if let token = MobileSyncService.pushToken(for: device), !token.isEmpty {
                        Label("Push", systemImage: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                        if let environment = pushChannelLabel(for: device) {
                            Text("• \(environment)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            copyTokenButton(for: device)
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
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func onlineStatePill(for device: PairedDevice) -> some View {
        switch device.onlineState {
        case .online:
            Label("Online", systemImage: "circle.fill")
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusSuccess)
                .labelStyle(.titleAndIcon)
        case .offline:
            Label("Offline", systemImage: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .unknown:
            EmptyView()
        }
    }

    /// Shows how sync traffic reaches this device: a green "Direct · LAN" chip
    /// when a peer-to-peer link is active, otherwise nothing (relay is implied
    /// by the existing online pill).
    private var directConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { MobileSyncService.directPathsEnabledSetting },
                set: { sync.setDirectPathsEnabled($0) }
            )) {
                Text("Direct peer-to-peer connections")
            }
            Text("When on the same network, sync connects straight to your device over the LAN (end-to-end encrypted) and falls back to the relay automatically. Turn off to always use relay servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pathPill(for device: PairedDevice) -> some View {
        let rtt = device.directRTTMillis.map { " · \($0)ms" } ?? ""
        switch device.activePath {
        case .directLAN:
            Label("Direct · LAN\(rtt)", systemImage: "bolt.horizontal.fill")
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusSuccess)
                .labelStyle(.titleAndIcon)
        case .directWAN:
            Label("Direct · WAN\(rtt)", systemImage: "bolt.horizontal.fill")
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.accentText)
                .labelStyle(.titleAndIcon)
        case .relay:
            EmptyView()
        }
    }

    @ViewBuilder
    private func copyTokenButton(for device: PairedDevice) -> some View {
        let token = MobileSyncService.pushToken(for: device)
        let copied = copiedTokenDeviceID == device.id
        Button {
            guard let token, !token.isEmpty else { return }
            copyToClipboard(token, feedback: Binding(
                get: { copiedTokenDeviceID == device.id },
                set: { copiedTokenDeviceID = $0 ? device.id : nil }
            ))
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? ClaudeTheme.statusSuccess : ClaudeTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .disabled(token?.isEmpty ?? true)
        .help(copied ? "Copied" : "Copy device token")
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
            .disabled(MobileSyncService.pushToken(for: device)?.isEmpty ?? true || sync.connectionState != .connected)
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
        if MobileSyncService.pushToken(for: device)?.isEmpty ?? true {
            let app = MobileSyncService.pushProvider(for: device) == "fcm" ? "RxCode on Android" : "RxCode Mobile"
            return "Open \(app) on this device once so it can register for push notifications."
        }
        if sync.connectionState != .connected {
            return "Connect to the relay before sending a test notification."
        }
        return "Send a push notification to \(device.displayName)."
    }

    private static func deviceIconName(for device: PairedDevice) -> String {
        let platform = device.platform.lowercased()
        if platform.contains("ipad") { return "ipad" }
        if platform.contains("android") { return "candybarphone" }
        return "iphone"
    }

    /// Provider-aware suffix shown next to the green "Push" badge. APNs shows
    /// sandbox/production; FCM shows "FCM" so it's clear how the push lands.
    private func pushChannelLabel(for device: PairedDevice) -> String? {
        switch MobileSyncService.pushProvider(for: device) {
        case "fcm": return "FCM"
        default: return apnsEnvironmentLabel(for: device)
        }
    }

    private func apnsEnvironmentLabel(for device: PairedDevice) -> String? {
        guard let raw = device.apnsEnvironment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty
        else { return nil }

        switch raw {
        case "sandbox", "development", "dev", "debug":
            return "Sandbox"
        case "production", "prod", "release":
            return "Production"
        default:
            return raw.capitalized
        }
    }
}

private struct TestNotificationAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Relay Server Editor Sheet

struct RelayServerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: MobileSyncService
    @State var catalog: RelayPresetCatalog
    let existingServer: SavedRelayServer?

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var selectedPresetID: String?
    @State private var usePreset: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text(existingServer == nil ? "Add Relay Server" : "Edit Relay Server")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                // Option to pick from presets
                if !catalog.presets.isEmpty {
                    Toggle("Use hosted relay", isOn: $usePreset)

                    if usePreset {
                        Picker("Select relay", selection: $selectedPresetID) {
                            Text("Choose…").tag(nil as String?)
                            ForEach(catalog.presets) { preset in
                                Text(preset.name).tag(Optional(preset.id))
                            }
                        }
                        .labelsHidden()

                        if let preset = catalog.presets.first(where: { $0.id == selectedPresetID }) {
                            Text(preset.url)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !usePreset {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("My Relay Server", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("wss://relay.example.com", text: $url)
                            .textFieldStyle(.roundedBorder)
                        if !url.isEmpty && !isValidURL {
                            Text("Enter a valid ws:// or wss:// URL.")
                                .font(.caption)
                                .foregroundStyle(ClaudeTheme.statusError)
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Spacer()
                Button(existingServer == nil ? "Add" : "Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .frame(width: 340)
        .padding(24)
        .onAppear {
            if let server = existingServer {
                name = server.name
                url = server.url
            }
        }
    }

    private var isValidURL: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              parsed.host?.isEmpty == false else { return false }
        return true
    }

    private var canSave: Bool {
        if usePreset {
            return selectedPresetID != nil
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isValidURL
    }

    private func save() {
        if usePreset, let presetID = selectedPresetID,
           let preset = catalog.presets.first(where: { $0.id == presetID })
        {
            let server = SavedRelayServer(
                name: preset.name,
                url: preset.url
            )
            sync.addRelayServer(server)
            // Start connection to the new server
            Task { await sync.startRelayServer(server) }
        } else {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

            if let existing = existingServer {
                var updated = existing
                updated.name = trimmedName
                updated.url = trimmedURL
                sync.updateRelayServer(updated)
                // Restart if URL changed
                if existing.url != trimmedURL {
                    Task {
                        await sync.stopRelayServer(existing)
                        await sync.startRelayServer(updated)
                    }
                }
            } else {
                let server = SavedRelayServer(
                    name: trimmedName,
                    url: trimmedURL
                )
                sync.addRelayServer(server)
                // Start connection to the new server
                Task { await sync.startRelayServer(server) }
            }
        }
    }
}
