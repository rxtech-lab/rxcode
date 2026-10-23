import SwiftUI

struct MobilePairedComputersView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: PairedDesktop?
    @State private var removing: PairedDesktop?
    @State private var name = ""
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List(state.pairedDesktops) { desktop in
                HStack {
                    Image(systemName: "desktopcomputer")
                    VStack(alignment: .leading) {
                        Text(desktop.displayName.isEmpty ? "Mac" : desktop.displayName)
                        if let relay = desktop.relayDisplayName {
                            Text(relay).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if desktop.id == state.activePairedDesktop?.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Active computer")
                    }
                    Menu {
                        if desktop.id != state.activePairedDesktop?.id {
                            Button("Use This Computer", systemImage: "desktopcomputer") {
                                MobileHaptics.buttonTap()
                                busy = true
                                status = "Switching computer…"
                                Task {
                                    await state.switchPairedDesktop(desktop)
                                    busy = false
                                    status = "Active computer updated"
                                    MobileHaptics.buttonTap()
                                }
                            }
                        }
                        Button("Rename", systemImage: "pencil") {
                            MobileHaptics.buttonTap()
                            name = desktop.displayName
                            renaming = desktop
                        }
                        Button("Remove Pairing", systemImage: "trash", role: .destructive) {
                            MobileHaptics.buttonTap()
                            removing = desktop
                        }
                    } label: {
                        Label("Manage Computer", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                }
                .disabled(busy)
            }
            .overlay {
                if state.pairedDesktops.isEmpty {
                    ContentUnavailableView("No Paired Computers", systemImage: "desktopcomputer",
                                           description: Text("Use Connect New Remote to pair a Mac."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let status {
                    HStack {
                        if busy { ProgressView() }
                        Text(status)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                    .accessibilityIdentifier("paired-computers-status")
                }
            }
            .navigationTitle("Paired Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { MobileHaptics.buttonTap(); dismiss() }
                        .disabled(busy)
                }
            }
            .alert("Rename Computer", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            )) {
                TextField("Computer name", text: $name)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { state.renamePairedDesktop(renaming, to: name) }
                    renaming = nil
                    MobileHaptics.buttonTap()
                    status = "Computer renamed"
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Remove pairing?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible) {
                Button("Remove Pairing", role: .destructive) {
                    guard let desktop = removing else { return }
                    removing = nil
                    MobileHaptics.buttonTap()
                    busy = true
                    status = "Removing pairing…"
                    Task {
                        await state.removePairedDesktop(desktop)
                        busy = false
                        status = "Pairing removed"
                        MobileHaptics.buttonTap()
                    }
                }
            } message: {
                Text("This removes the computer from this device. You can pair it again later.")
            }
        }
        .interactiveDismissDisabled(busy)
        .task(id: status) {
            guard status != nil, !busy else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            status = nil
        }
    }
}
