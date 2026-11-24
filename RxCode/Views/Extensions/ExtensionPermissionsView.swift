import RxCodeCore
import SwiftUI

struct ExtensionPermissionsView: View {
    let manifest: ExtensionManifest
    let identity: String
    let editable: Bool
    @State private var error: String?
    @State private var changing = Set<ExtensionPermission.ID>()
    private let store = ExtensionPermissionStore.shared

    var body: some View {
        List(manifest.effectivePermissions) { permission in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: permission.id.rawValue).font(.system(.body, design: .monospaced))
                    Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
                    if let values = permission.domains ?? permission.slots {
                        Text(verbatim: values.joined(separator: ", ")).font(.caption).textSelection(.enabled)
                    }
                }
                Spacer()
                switch permission.risk {
                case .implicit: Text("Default").foregroundStyle(.secondary)
                case .standard: Text("Standard").foregroundStyle(.secondary)
                case .high:
                    Text("High risk").foregroundStyle(.orange)
                    if editable {
                        Menu {
                            Button("Confirm") { save(.confirm, permission) }
                            Button("Skip") { save(.skip, permission) }
                            Button("Reject") { save(.reject, permission) }
                        } label: {
                            switch store.decision(for: permission, identity: identity) {
                            case .confirm: Text("Confirmed")
                            case .reject: Text("Rejected")
                            case .skip, nil: Text("Pending")
                            }
                        }
                        .disabled(changing.contains(permission.id))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !changing.isEmpty { ProgressView().padding().background(.regularMaterial, in: Capsule()) }
        }
        .task {
            do { try await store.load() } catch { self.error = error.localizedDescription }
        }
        .alert("Permission update failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func save(_ decision: ExtensionPermissionDecisions.Decision, _ permission: ExtensionPermission) {
        changing.insert(permission.id)
        Task {
            defer { changing.remove(permission.id) }
            do { try await store.set(decision, permission: permission, identity: identity) }
            catch { self.error = error.localizedDescription }
        }
    }
}
