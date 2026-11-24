import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import SwiftUI

struct ExtensionInstallSheet: View {
    private enum Operation {
        case install(ExtensionCatalogItem, updating: Bool)
        case enable(InstalledExtensionMetadata)
    }
    private let operation: Operation
    private var fixedWorkspace: URL?

    init(item: ExtensionCatalogItem, updating: Bool) { operation = .install(item, updating: updating) }
    init(enabling item: InstalledExtensionMetadata, workspace: URL? = nil) {
        operation = .enable(item)
        fixedWorkspace = workspace
    }

    private var name: String {
        switch operation {
        case .install(let release, _): release.name
        case .enable(let item): item.name
        }
    }
    private var version: String {
        switch operation {
        case .install(let release, _): release.version
        case .enable(let item): item.manifest?.version ?? item.version ?? ""
        }
    }
    private var title: LocalizedStringKey {
        switch operation {
        case .install(_, true): "Update Extension"
        case .install(_, false): "Install Extension"
        case .enable: "Enable Extension"
        }
    }
    private var actionTitle: LocalizedStringKey {
        switch operation {
        case .install(_, true): "Update"
        case .install(_, false): "Install"
        case .enable: "Enable"
        }
    }
    @Environment(WorkspaceManager.self) private var workspaces
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: URL?
    @State private var choices: [URL] = []
    @State private var installing = false
    @State private var error: String?
    @State private var unknownKey = false
    private let catalog = ExtensionCatalogController.shared

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Extension", value: name)
                LabeledContent("Version", value: version)
                if let fixedWorkspace {
                    LabeledContent("Project or worktree", value: fixedWorkspace.path)
                } else {
                    Picker("Project or worktree", selection: $workspace) {
                        Text("Choose a project").tag(nil as URL?)
                        ForEach(choices, id: \.self) { url in
                            Text(verbatim: url.path).tag(Optional(url))
                        }
                    }
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                if !choices.contains(url) { choices.append(url) }
                                workspace = url
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(installing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { if let workspace { install(workspace) } } label: {
                        Text(actionTitle)
                    }
                    .disabled(installing || workspace == nil)
                }
            }
        }
        .sheet(isPresented: Binding(get: { catalog.enablementRequested }, set: { catalog.enablementRequested = $0 })) {
            NavigationStack {
                SystemExtensionBrowser()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Enable Extension")
                    .toolbar { Button("Cancel") { catalog.enablementRequested = false } }
            }
            .frame(minWidth: 540, idealWidth: 620, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        }
        .interactiveDismissDisabled(installing)
        .overlay { if installing { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .frame(minWidth: 500, idealWidth: 620, maxWidth: .infinity, minHeight: 380, idealHeight: 460, maxHeight: .infinity)
        .onAppear {
            if let fixedWorkspace { workspace = fixedWorkspace; return }
            let state = workspaces.frontmostAppState
            let open = state.registeredWindows().compactMap { state.effectiveCwd(in: $0) }
            choices = Set(open + state.projects.filter { !$0.isGlobalChat }.map(\.path))
                .sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
            if choices.count == 1 { workspace = choices.first }
        }
        .alert("Extension installation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            if unknownKey { Button("Check for RxCode Updates") { UpdateService.shared.checkForUpdates() } }
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func install(_ workspace: URL) {
        installing = true
        Task {
            defer { installing = false }
            do {
                switch operation {
                case .install(let item, _): try await catalog.install(item, workspace: workspace)
                case .enable(let item):
                    guard let id = item.manifest?.id else { throw ExtensionVerificationError.invalidPayload }
                    try await catalog.setEnabled(true, id: id, workspace: workspace)
                }
                dismiss()
            }
            catch ExtensionVerificationError.unknownKey {
                unknownKey = true
                error = String(localized: "Update couldn't be verified. This version of RxCode doesn't recognize its signing key.")
            } catch { unknownKey = false; self.error = error.localizedDescription }
        }
    }
}
