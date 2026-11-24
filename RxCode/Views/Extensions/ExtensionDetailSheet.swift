import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Detail

struct ExtensionDetailSheet: View {
    let initialItem: InstalledExtensionMetadata
    let workspace: URL?
    let sceneState: AppState?
    @Environment(WorkspaceManager.self) private var workspaces

    init(item: InstalledExtensionMetadata, workspace: URL? = nil, sceneState: AppState? = nil) {
        self.sceneState = sceneState
        initialItem = item
        self.workspace = workspace
    }
    @State private var selectedWorkspace: URL?
    @State private var chosenFolder: URL?
    private let catalog = ExtensionCatalogController.shared
    @State private var confirmUninstall = false
    @State private var confirmDisable = false
    @State private var enableSheet = false
    @State private var disabling = false
    @State private var removing = false
    @State private var error: String?

    private var item: InstalledExtensionMetadata {
        if let id = initialItem.manifest?.id, initialItem.verification != nil { return catalog.installed[id] ?? initialItem }
        return initialItem
    }
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case overview, permissions, settings }
    @State private var tab = Tab.overview
    private var sessions: [ActivatedExtension] {
        guard ExtensionPluginAPI.v2Enabled else { return [] }
        return AgentExtensionRuntime.shared.panels.filter { $0.bundleIdentifier == item.bundleIdentifier }
    }
    private var state: AppState { sceneState ?? workspaces.frontmostAppState }
    private var projectChoices: [URL] {
        if let workspace { return [workspace] }
        var paths: [String]
        if item.verification != nil {
            paths = []
            paths += state.registeredWindows().compactMap { state.effectiveCwd(in: $0) }
            paths += state.projects.filter { !$0.isGlobalChat }.map(\.path)
            if let chosenFolder { paths.append(chosenFolder.path) }
        } else {
            paths = sessions.map { $0.workspace.path }
        }
        return Set(paths.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath() })
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private var currentWorkspace: URL? {
        if let workspace { return workspace }
        if let selectedWorkspace, projectChoices.contains(selectedWorkspace) { return selectedWorkspace }
        return projectChoices.count == 1 ? projectChoices.first : nil
    }
    private var activated: ActivatedExtension? {
        guard let currentWorkspace else { return nil }
        return sessions.first { $0.workspace.path == currentWorkspace.path }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ExtensionPluginAPI.v2Enabled, let manifest = activated?.manifest ?? item.manifest {
                    Picker("Extension Details", selection: $tab) {
                        Text("Overview").tag(Tab.overview)
                        Text("Permissions").tag(Tab.permissions)
                        if manifest.contributes.settings == true { Text("Settings").tag(Tab.settings) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding()
                    switch tab {
                    case .overview: overview
                    case .permissions:
                        ExtensionPermissionsView(manifest: manifest, identity: item.verification == nil ? item.bundleIdentifier : manifest.id,
                                                 editable: item.isDevelopment || item.verification != nil)
                    case .settings:
                        if workspace == nil {
                            HStack {
                                Picker("Project or worktree", selection: Binding(get: { currentWorkspace }, set: { selectedWorkspace = $0 })) {
                                    Text("Choose a project").tag(nil as URL?)
                                    ForEach(projectChoices, id: \.self) { choice in
                                        Text(verbatim: choice.path).tag(Optional(choice))
                                    }
                                }
                                if item.verification != nil {
                                    Button("Choose Folder…") { chooseFolder() }
                                }
                            }
                            .padding(.horizontal)
                        }
                        if let currentWorkspace {
                            InstalledExtensionScene(item: item, scene: "settings", workspace: currentWorkspace, state: state)
                        } else {
                            ContentUnavailableView("Choose a project", systemImage: "folder")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    overview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if item.verification != nil, let id = item.manifest?.id {
                    ToolbarItem {
                        Menu("Manage Extension") {
                            if catalog.disabledIDs.contains(id) {
                                Button("Enable…") { enableSheet = true }
                            } else {
                                Button("Disable…") { confirmDisable = true }
                            }
                            Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                        }
                    }
                }
                if let container = item.containerURL {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([container])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $enableSheet) { ExtensionInstallSheet(enabling: item, workspace: currentWorkspace) }
        .confirmationDialog("Disable this extension?", isPresented: $confirmDisable) {
            Button("Disable") {
                guard let id = item.manifest?.id else { return }
                disabling = true
                Task {
                    defer { disabling = false }
                    do { try await catalog.setEnabled(false, id: id, workspace: workspace) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Uninstall this extension?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                guard let id = item.manifest?.id else { return }
                removing = true
                Task {
                    defer { removing = false }
                    do { try await catalog.uninstall(id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay { if removing || disabling { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .alert("Extension update failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let folder = panel.url?.standardizedFileURL.resolvingSymlinksInPath() else { return }
            chosenFolder = folder
            selectedWorkspace = folder
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            header
            if let verification = item.verification {
                VStack(alignment: .leading, spacing: 8) {
                    if verification.blocked {
                        Label("Extension blocked · update required", systemImage: "nosign").foregroundStyle(.red)
                    } else if ["test-active", "test-backup"].contains(verification.keyId) {
                        Label("Signed with a test key · Verified by RxCode.", systemImage: "checkmark.seal")
                    } else {
                        Label("Signed by rxlab · Verified by RxCode.", systemImage: "checkmark.seal")
                    }
                    if let id = item.manifest?.id, catalog.unknownSigningKeyUpdates.contains(id) {
                        Label("Update couldn't be verified. This version of RxCode doesn't recognize its signing key.", systemImage: "exclamationmark.triangle")
                        Button("Check for RxCode Updates") { UpdateService.shared.checkForUpdates() }
                    }
                    if let id = item.manifest?.id, catalog.disabledIDs.contains(id) {
                        Label("Disabled", systemImage: "pause.circle")
                    }
                    DisclosureGroup("Verification details") {
                        Grid(alignment: .leading) {
                            GridRow { Text("Source"); Text(verbatim: verification.source) }
                            GridRow { Text("Key ID"); Text(verbatim: verification.keyId) }
                            GridRow { Text("Key fingerprint"); Text(verbatim: verification.fingerprint) }
                            GridRow { Text("Archive SHA-256"); Text(verbatim: verification.sha256) }
                            if let date = catalog.revocationsRefreshedAt {
                                GridRow { Text("Revocations last refreshed"); Text(date.formatted()) }
                            }
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)
            } else if item.isDevelopment {
                Label("Local development build.", systemImage: "hammer")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            if let warning = ExtensionPluginAPI.warning(for: item.compatibility) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Compatibility Warning")
                            .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        Text(verbatim: warning)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(ClaudeTheme.statusWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            ClaudeThemeDivider()
            readme
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ExtensionIconView(icon: item.icon, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name)
                    .font(.system(size: ClaudeTheme.size(18), weight: .semibold))
                Text(verbatim: item.bundleIdentifier)
                    .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    APIVersionBadge(version: item.pluginAPIVersion, compatible: item.compatibility.isCompatible)
                    Text(verbatim: "Host API \(ExtensionPluginAPI.version)")
                        .font(.system(size: ClaudeTheme.size(10.5)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    if let version = item.version {
                        Text(verbatim: "· Version \(version)")
                            .font(.system(size: ClaudeTheme.size(10.5)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder private var readme: some View {
        if let text = item.readme, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownPreviewView(content: text, baseURL: item.readmeBaseURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No README", systemImage: "doc.text",
                                   description: Text("This extension does not include a README.md."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
