import RxCodeCore
import SwiftUI

struct ExtensionsInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var window
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showExtensionsSettings") private var showExtensionsSettings = false
    @State private var selectedID: String?
    @State private var detail: InstalledExtensionMetadata?
    @State private var developmentMetadata: [InstalledExtensionMetadata] = []
    @State private var loadError: String?
    private let catalog = ExtensionCatalogController.shared

    private var workspace: URL? {
        guard ExtensionPluginAPI.v2Enabled, let path = appState.effectiveCwd(in: window) else { return nil }
        return URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private var developmentPanels: [ActivatedExtension] {
        guard let workspace else { return [] }
        return AgentExtensionRuntime.shared.panels.filter {
            $0.workspace.path == workspace.path && $0.revalidate == nil && $0.manifest.contributes.inspectorPanel != nil
        }
    }

    private var rows: [InstalledExtensionMetadata] {
        let distributed = catalog.installed.values.filter { $0.manifest?.contributes.inspectorPanel != nil }
        let developmentIDs = Set(developmentPanels.map(\.bundleIdentifier))
        return (distributed + developmentMetadata.filter { developmentIDs.contains($0.bundleIdentifier) }).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if let item = rows.first(where: { $0.id == selectedID }), let workspace {
                VStack(spacing: 0) {
                    HStack {
                        Button { selectedID = nil } label: { Label("Back", systemImage: "chevron.backward") }
                        Text(verbatim: item.manifest?.contributes.inspectorPanel?.title ?? item.name)
                        Spacer()
                        infoButton(item)
                    }
                    .padding(8)
                    Divider()
                    InstalledExtensionScene(item: item, scene: "inspector", workspace: workspace, state: appState)
                }
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Extension Panels", systemImage: "puzzlepiece.extension")
                } description: {
                    if let loadError { Text(verbatim: loadError) }
                } actions: {
                    Button("Open Extension Settings") {
                        showExtensionsSettings = true
                        openSettings()
                    }
                }
            } else {
                List(rows) { item in
                    HStack {
                        Button { selectedID = item.id } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(verbatim: item.manifest?.contributes.inspectorPanel?.title ?? item.name)
                                    if item.verification?.blocked == true {
                                        Text("Extension blocked · update required").font(.caption).foregroundStyle(.secondary)
                                    } else if item.verification != nil, let id = item.manifest?.id, catalog.disabledIDs.contains(id) {
                                        Text("Disabled").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: item.manifest?.contributes.inspectorPanel?.symbol ?? "puzzlepiece.extension")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace == nil)
                        infoButton(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: workspace) {
            guard ExtensionPluginAPI.v2Enabled else { return }
            do { try await catalog.loadInstalledMetadata(); loadError = nil }
            catch is CancellationError {} catch { loadError = error.localizedDescription }
        }
        .task(id: developmentPanels.map { $0.workspace.path + "/" + $0.bundleIdentifier + "/" + $0.generation }) {
            let requests = developmentPanels.map { ($0.bundleIdentifier, $0.manifest) }
            let metadata = await Task.detached {
                requests.map { id, manifest in
                    var item = InstalledExtensionMetadata.load(bundleIdentifier: id, localizedName: manifest.name)
                    item.manifest = manifest
                    return item
                }
            }.value
            guard !Task.isCancelled else { return }
            developmentMetadata = metadata
        }
        .sheet(item: $detail) { item in
            ExtensionDetailSheet(item: item, workspace: workspace, sceneState: appState)
        }
    }

    private func infoButton(_ item: InstalledExtensionMetadata) -> some View {
        Button { detail = item } label: { Label("Extension Details", systemImage: "info.circle") }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }
}
