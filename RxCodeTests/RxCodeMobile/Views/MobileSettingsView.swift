import SwiftUI

struct MobileSettingsView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    HStack {
                        Image(systemName: "desktopcomputer").frame(width: 22)
                        Text(state.pairedDesktopName.isEmpty ? "Unknown Mac" : state.pairedDesktopName)
                    }
                    HStack {
                        Text("Connection")
                        Spacer()
                        connectionLabel
                    }
                    HStack {
                        Text("Relay")
                        Spacer()
                        Text(state.relayURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showUnpairConfirm = true
                    } label: {
                        Label("Unpair", systemImage: "minus.circle")
                    }
                } footer: {
                    Text("Unpairing regenerates this device's identity. You'll need to scan a fresh QR to re-pair.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Unpair this device?", isPresented: $showUnpairConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Unpair", role: .destructive) {
                    Task { await state.unpair() }
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch state.connectionState {
        case .connected:
            Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
        case .disconnected:
            Label("Disconnected", systemImage: "circle.slash").foregroundStyle(.secondary)
        case .reconnecting:
            Label("Reconnecting…", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
        }
    }
}
