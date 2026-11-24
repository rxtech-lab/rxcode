import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import SwiftUI

struct UsageExtensionActionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let integration: UsageIntegration
    let action: UsageExtensionStatus
    @State private var busy = false
    @State private var error: String?
    @State private var showSystemSettings = false
    private let catalog = ExtensionCatalogController.shared

    private var permissionContext: (manifest: ExtensionManifest, identity: String)? {
        if let manifest = catalog.usageMetadata(integration.pluginID)?.manifest { return (manifest, manifest.id) }
        guard let root = appState.usageExtensionWorkspace(for: integration),
              let panel = catalog.installedUsagePanel(pluginID: integration.pluginID, workspace: root) else { return nil }
        return (panel.manifest, panel.permissionIdentity)
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(Text(LocalizedStringKey(action.rawValue)))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action == .permissions || showSystemSettings ? "Done" : "Continue") { perform() }.disabled(busy)
                    }
                }
        }
        .frame(minWidth: 500, idealWidth: 620, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: Binding(get: { catalog.enablementRequested }, set: { catalog.enablementRequested = $0 })) {
            NavigationStack {
                SystemExtensionBrowser()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Enable Extension")
                    .toolbar { Button("Cancel") { catalog.enablementRequested = false } }
            }.frame(minWidth: 540, minHeight: 480, maxHeight: .infinity)
        }
        .task {
            guard action == .permissions, let context = permissionContext else { return }
            do {
                try await ExtensionPermissionStore.shared.review(manifest: context.manifest, identity: context.identity)
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
        .alert("Extension update failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var content: some View {
        if action == .permissions, let context = permissionContext {
            ExtensionPermissionsView(manifest: context.manifest, identity: context.identity, editable: true)
        } else if showSystemSettings {
            SystemExtensionBrowser()
        } else {
            Form { LabeledContent("Integration", value: integration.title) }.formStyle(.grouped)
        }
    }

    private func refresh() async {
        guard appState.usageDashboard.integrations.contains(integration) else { return }
        await appState.refreshUsageIntegration(integration)
        await appState.persistUsageDashboard()
    }

    private func perform() {
        guard let workspace = appState.usageExtensionWorkspace(for: integration) else {
            error = UsageExtensionStatus.unavailable.localizedDescription
            return
        }
        let id = catalog.usageMetadata(integration.pluginID)?.manifest?.id ?? BundledUsageExtensions.releaseID(for: integration.pluginID)
        if action == .enable, catalog.needsSystemEnablement.contains(id), !showSystemSettings {
            showSystemSettings = true
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                if integration.projectID == nil { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true) }
                switch action {
                case .enable where !showSystemSettings: try await catalog.setEnabled(true, id: id, workspace: workspace)
                case .install, .blocked:
                    if action == .install {
                        do { try await catalog.seedUsage(integration.pluginID, workspace: workspace, explicit: true) }
                        catch ExtensionVerificationError.revoked { /* An online release may replace the revoked seed. */ }
                    }
                    if catalog.usageMetadata(integration.pluginID) == nil || action == .blocked {
                        try await catalog.refresh()
                        guard let release = catalog.available.first(where: { $0.id == id }) else { throw UsageExtensionStatus.unavailable }
                        try await catalog.install(release, workspace: workspace)
                    }
                default: break
                }
                await refresh()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
