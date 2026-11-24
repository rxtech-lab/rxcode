import RxCodeCore
import SwiftUI

/// A user opening this scene may revisit pending decisions. Broker calls made
/// after it opens use background authorization and never present another prompt.
struct ReviewedExtensionScene: View {
    let panel: ActivatedExtension
    let scene: String
    @State private var reviewedGeneration: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Permission review failed", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if reviewedGeneration == panel.generation {
                ExtensionSceneView(extension: panel, scene: scene)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: panel.generation) {
            failure = nil
            do {
                try await ExtensionPermissionStore.shared.review(manifest: panel.manifest, identity: panel.permissionIdentity)
                try Task.checkCancellation()
                reviewedGeneration = panel.generation
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

/// Opens one installed contribution for the window or project selected by the user.
struct InstalledExtensionScene: View {
    let item: InstalledExtensionMetadata
    let scene: String
    let workspace: URL
    let state: AppState
    private let catalog = ExtensionCatalogController.shared
    @State private var failure: String?
    @State private var retry = 0
    @State private var enabling = false

    private var disabled: Bool {
        item.verification != nil && (item.manifest.map { catalog.disabledIDs.contains($0.id) } ?? false)
    }
    private var needsEnablement: Bool {
        item.verification != nil && (item.manifest.map { catalog.needsSystemEnablement.contains($0.id) } ?? false)
    }
    private var panel: ActivatedExtension? {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        return AgentExtensionRuntime.shared.panels.first {
            $0.bundleIdentifier == item.bundleIdentifier && $0.workspace.path == root.path && $0.manifest.contributes.sceneIDs.contains(scene)
        }
    }

    var body: some View {
        Group {
            if item.verification?.blocked == true {
                ContentUnavailableView("Extension blocked · update required", systemImage: "nosign")
            } else if disabled {
                ContentUnavailableView {
                    Label("Disabled", systemImage: "pause.circle")
                } actions: {
                    Button("Enable Extension") { enabling = true }
                }
            } else if let panel {
                ReviewedExtensionScene(panel: panel, scene: scene)
                    .id(ObjectIdentifier(panel.broker))
            } else if needsEnablement {
                ContentUnavailableView {
                    Label("Enable Extension", systemImage: "puzzlepiece.extension")
                } actions: {
                    Button("Manage Extensions…") { enabling = true }
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Extension unavailable", systemImage: "puzzlepiece.extension")
                } description: {
                    Text(verbatim: failure)
                } actions: {
                    Button("Retry") { retry += 1 }
                }
            } else if item.verification != nil {
                ProgressView()
            } else {
                ContentUnavailableView("Extension unavailable", systemImage: "puzzlepiece.extension")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $enabling, onDismiss: { retry += 1 }) {
            if disabled { ExtensionInstallSheet(enabling: item, workspace: workspace) }
            else {
                NavigationStack {
                    SystemExtensionBrowser()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Manage Extensions")
                        .toolbar { Button("Done") { enabling = false } }
                }
                .frame(minWidth: 540, minHeight: 480)
            }
        }
        .task(id: LoadID(item: item.id, sha256: item.verification?.sha256, blocked: item.verification?.blocked == true,
                         disabled: disabled, workspace: workspace, retry: retry)) {
            failure = nil
            guard item.verification?.blocked == false, !disabled else { return }
            do { try await catalog.openScene(scene, item: item, workspace: workspace, state: state) }
            catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private struct LoadID: Hashable {
        let item: String
        let sha256: String?
        let blocked: Bool
        let disabled: Bool
        let workspace: URL
        let retry: Int
    }
}
