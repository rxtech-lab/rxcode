import AppKit
import RxCodeCore
import SwiftUI

/// Browse, download and manage the local models the RxCode Agent runs.
///
/// A two-column split view: the sidebar holds a segmented control for the
/// Hugging Face catalog, the signed-in account's repos and what is installed,
/// above that section's list; the detail column shows the selected model —
/// its quantizations to download, or an installed model's details.
struct LocalModelsSheet: View {
    enum Section: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case mine = "My Models"
        case installed = "Installed"
        var id: String { rawValue }
    }

    enum InstalledSelection: Hashable {
        case settings
        case model(String)
    }

    var initialModel: LocalModelSheetRequest? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .browse
    @State private var remoteSelection: HFModelSummary?
    @State private var installedSelection: InstalledSelection?
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var pendingDownload: PendingDownload?
    @State private var pendingDeletion: LocalModelInfo?
    @State private var showSignIn = false
    @State private var loadingInitialModel = false

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 380, ideal: 400, max: 480)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        HuggingFaceAccountButton(showSignIn: $showSignIn)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: initialModel?.id) {
            guard let request = initialModel else { return }
            loadingInitialModel = true
            defer { loadingInitialModel = false }
            do {
                remoteSelection = try await HuggingFaceClient.model(request.repoID, format: request.format)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { progressOverlay }
        .overlay {
            if loadingInitialModel {
                ProgressView("Loading model…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: section) {
            remoteSelection = nil
            installedSelection = nil
        }
        .onChange(of: store.installed) {
            if case .model(let id) = installedSelection, !store.installed.contains(where: { $0.id == id }) {
                installedSelection = nil
            }
        }
        .sheet(isPresented: $showSignIn) {
            HuggingFaceSignInSheet()
                .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 520)
        }
        .alert("Download a large model?", isPresented: Binding(
            get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }
        ), presenting: pendingDownload) { pending in
            Button("Cancel", role: .cancel) { pendingDownload = nil }
            Button("Download") { startDownload(pending) }
        } message: { pending in
            Text(largeModelWarning(pending))
        }
        .alert("Delete model?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { model in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) { delete(model) }
        } message: { model in
            Text("“\(model.displayName)” (\(LocalModelFormat.bytes(model.sizeBytes))) will be removed from this Mac.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Group {
                switch section {
                case .browse: LocalModelBrowseView(selection: $remoteSelection, initialModel: initialModel)
                case .mine: myModels
                case .installed: installedList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                hardwareFooter
            }
            .background(.bar)
        }
    }

    // MARK: - Hardware

    private var hardwareFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.hardware.chip).font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    Text("\(store.hardware.memoryDescription) memory · \(LocalModelFormat.bytes(store.hardware.gpuBudgetBytes)) usable by the GPU")
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "memorychip")
            }
            runtimeControls
            serverControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Runtimes install on demand with the first download of their format,
    /// so the footer only reports what is already installed.
    @ViewBuilder
    private var runtimeControls: some View {
        if store.mlxRuntime != nil || store.runtime != nil {
            HStack(spacing: 12) {
                if let runtime = store.mlxRuntime {
                    Label("MLX \(runtime.version)", systemImage: "checkmark.circle.fill")
                }
                if let runtime = store.runtime {
                    Label("llama.cpp \(runtime.version)", systemImage: "checkmark.circle.fill")
                }
            }
            .font(.system(size: ClaudeTheme.size(10)))
            .foregroundStyle(ClaudeTheme.statusSuccess)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var serverControls: some View {
        switch store.serverStatus {
        case .running(let modelID, _, let context):
            HStack(spacing: 6) {
                LocalServerStatusBadge(status: store.serverStatus)
                Text("\(store.installed.first { $0.id == modelID }?.displayName ?? modelID) · \(context.formatted()) ctx")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Unload") {
                    Task {
                        await store.unloadServer()
                        showStatus("Model unloaded. Memory released.")
                    }
                }
                .controlSize(.small)
            }
        case .loading, .failed:
            LocalServerStatusBadge(status: store.serverStatus)
        case .stopped:
            EmptyView()
        }
    }

    // MARK: - My Models

    @ViewBuilder
    private var myModels: some View {
        if let account = store.huggingFace.account {
            LocalModelBrowseView(author: account.username, selection: $remoteSelection)
                .id(account.username)
        } else {
            ContentUnavailableView {
                Label("Sign In to See Your Models", systemImage: "person.crop.circle")
            } description: {
                Text("Sign in to Hugging Face to browse and download the models you uploaded, including private ones.")
            } actions: {
                Button("Sign In to Hugging Face…") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Installed

    private var installedList: some View {
        List {
            SwiftUI.Section {
                Label("Memory & Context", systemImage: "slider.horizontal.3")
                    .padding(.vertical, 2)
                    .selectableModelRow(isSelected: installedSelection == .settings) { installedSelection = .settings }
            }
            SwiftUI.Section("Models") {
                if store.installed.isEmpty {
                    Text("No models downloaded")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.installed) { model in
                    InstalledModelRow(
                        model: model,
                        isDefault: store.settings.defaultModelID == model.id,
                        fit: store.fit(bytes: model.sizeBytes)
                    )
                    .selectableModelRow(isSelected: installedSelection == .model(model.id)) {
                        installedSelection = .model(model.id)
                    }
                    .contextMenu {
                        Button("Make Default") { store.settings.defaultModelID = model.id }
                            .disabled(store.settings.defaultModelID == model.id)
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeletion = model }
                    }
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .browse, .mine:
            if let summary = remoteSelection {
                LocalModelDetailView(summary: summary, onDownload: requestDownload)
                    .id(summary.id)
            } else {
                ContentUnavailableView(
                    "Select a Model",
                    systemImage: "cube.transparent",
                    description: Text("Choose a model from the list to see its files and download one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .installed:
            switch installedSelection {
            case .settings:
                runtimeSettings
            case .model(let id):
                if let model = store.installed.first(where: { $0.id == id }) {
                    InstalledModelDetailView(
                        model: model,
                        directory: model.directory(in: store.modelsRoot),
                        isDefault: store.settings.defaultModelID == model.id,
                        fit: store.fit(bytes: model.sizeBytes),
                        onMakeDefault: { store.settings.defaultModelID = model.id },
                        onDelete: { pendingDeletion = model }
                    )
                } else {
                    installedPlaceholder
                }
            case nil:
                installedPlaceholder
            }
        }
    }

    @ViewBuilder
    private var installedPlaceholder: some View {
        if store.installed.isEmpty {
            ContentUnavailableView(
                "No Local Models",
                systemImage: "shippingbox",
                description: Text("Download a model from Browse to use the RxCode Agent.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Model",
                systemImage: "shippingbox",
                description: Text("Choose an installed model to see its details.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var runtimeSettings: some View {
        @Bindable var store = store
        return Form {
            SwiftUI.Section {
                Picker("Release memory when idle for", selection: $store.settings.idleMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
                Picker("Context window", selection: $store.settings.contextSize) {
                    Text("Automatic (\(store.hardware.defaultContextSize.formatted()) tokens)").tag(Int?.none)
                    ForEach([8_192, 16_384, 32_768, 65_536, 131_072], id: \.self) { size in
                        Text("\(size.formatted()) tokens").tag(Int?.some(size))
                    }
                }
            } header: {
                Text("Runtime")
            } footer: {
                Text("The model is loaded on first use and unloaded after the idle period to free memory. Larger context windows use more memory; the model's own maximum always applies.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory & Context")
    }

    // MARK: - Overlay

    @ViewBuilder
    private var progressOverlay: some View {
        // Download progress lives in the Downloads window; this only
        // confirms finished actions.
        if let status {
            HStack {
                Text(status)
                Spacer()
                Button("Dismiss") { self.status = nil }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
    }

    // MARK: - Actions

    struct PendingDownload: Identifiable {
        var id: String { summary.id + "/" + variant.id }
        let summary: HFModelSummary
        let variant: HFModelVariant
    }

    private func requestDownload(summary: HFModelSummary, variant: HFModelVariant) {
        // Private and gated files answer 401 without a token; ask first
        // instead of failing the download.
        if (summary.isPrivate || summary.isGated) && !store.huggingFace.isSignedIn {
            showSignIn = true
            return
        }
        let pending = PendingDownload(summary: summary, variant: variant)
        if store.fit(bytes: variant.sizeBytes).needsWarning || variant.sizeBytes > 20 * 1_073_741_824 {
            pendingDownload = pending
        } else {
            startDownload(pending)
        }
    }

    private func startDownload(_ pending: PendingDownload) {
        pendingDownload = nil
        Task {
            do {
                // The search API's context length is missing for MLX repos and
                // some GGUF ones; fetch it so the server is sized correctly.
                var summary = pending.summary
                if summary.contextLength == nil {
                    let format = summary.format
                    let full = try? await HuggingFaceClient.model(summary.id, format: format)
                    let mlxContext = format == .mlx ? (try? await HuggingFaceClient.mlxConfig(of: summary.id))?.contextLength : nil
                    summary = HFModelSummary(
                        id: summary.id, author: full?.author ?? summary.author,
                        downloads: full?.downloads ?? summary.downloads, likes: full?.likes ?? summary.likes,
                        parameterCount: summary.parameterCount ?? full?.parameterCount,
                        contextLength: mlxContext ?? full?.contextLength,
                        architecture: summary.architecture ?? full?.architecture,
                        lastModified: full?.lastModified, format: format,
                        isPrivate: summary.isPrivate, isGated: summary.isGated,
                        pipelineTag: full?.pipelineTag ?? summary.pipelineTag,
                        libraryName: full?.libraryName ?? summary.libraryName, tags: full?.tags ?? summary.tags
                    )
                }
                if store.runtime(for: summary.format) == nil { try await store.installRuntime(for: summary.format) }
                try await store.download(summary: summary, variant: pending.variant)
                showStatus("Downloaded \(summary.name) · \(pending.variant.displayName).")
            } catch is CancellationError {
                showStatus("Download cancelled.")
            } catch LocalModelDownloader.DownloadError.cancelled {
                showStatus("Download cancelled.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ model: LocalModelInfo) {
        pendingDeletion = nil
        status = "Deleting \(model.displayName)…"
        Task {
            await store.delete(model)
            showStatus("Deleted \(model.displayName).")
        }
    }

    private func showStatus(_ text: String) {
        status = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if status == text { status = nil }
        }
    }

    private func largeModelWarning(_ pending: PendingDownload) -> String {
        let fit = store.fit(bytes: pending.variant.sizeBytes)
        let size = LocalModelFormat.bytes(pending.variant.sizeBytes)
        let memory = store.hardware.memoryDescription
        switch fit {
        case .tooLarge:
            return "This model is \(size), more than this Mac's \(memory) of memory can hold for the GPU. It will likely fail to load or run very slowly."
        case .tight:
            return "This model is \(size) and will use nearly all of this Mac's \(memory) of memory, which can slow down other apps."
        case .recommended, .fits:
            return "This model is \(size). Make sure you have enough free disk space; the download can take a while."
        }
    }
}

// MARK: - Rows

struct LocalModelFitBadge: View {
    let fit: LocalModelFit

    var body: some View {
        Label(fit.label, systemImage: fit.systemImage)
            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch fit {
        case .recommended, .fits: ClaudeTheme.statusSuccess
        case .tight: ClaudeTheme.statusWarning
        case .tooLarge: ClaudeTheme.statusError
        }
    }
}

private struct InstalledModelRow: View {
    let model: LocalModelInfo
    let isDefault: Bool
    let fit: LocalModelFit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDefault {
                    Text("Default")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(ClaudeTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Text(model.format.label)
                Text(LocalModelFormat.bytes(model.sizeBytes))
                Spacer(minLength: 0)
                LocalModelFitBadge(fit: fit)
            }
            .font(.system(size: ClaudeTheme.size(10)))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// An installed model's details and the actions that change it.
private struct InstalledModelDetailView: View {
    let model: LocalModelInfo
    let directory: URL
    let isDefault: Bool
    let fit: LocalModelFit
    let onMakeDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            SwiftUI.Section("Model") {
                LabeledContent("Repository", value: model.repoID)
                LabeledContent("Author", value: model.author)
                LabeledContent("Format", value: model.format.label)
                if let quantization = model.quantization { LabeledContent("Quantization", value: quantization) }
                if let params = LocalModelFormat.parameters(model.parameterCount) { LabeledContent("Parameters", value: params) }
                if let architecture = model.architecture { LabeledContent("Architecture", value: architecture) }
                if let context = model.contextLength { LabeledContent("Max context", value: "\(context.formatted()) tokens") }
            }
            SwiftUI.Section("On This Mac") {
                LabeledContent("Size", value: LocalModelFormat.bytes(model.sizeBytes))
                LabeledContent("Memory fit") { LocalModelFitBadge(fit: fit) }
                LabeledContent("Downloaded", value: model.downloadedAt.formatted(date: .abbreviated, time: .shortened))
                if model.files.count > 1 { LabeledContent("Files", value: model.files.count.formatted()) }
            }
            SwiftUI.Section {
                Button(isDefault ? "Default Model" : "Make Default", action: onMakeDefault)
                    .disabled(isDefault)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                Button("Delete…", role: .destructive, action: onDelete)
            } footer: {
                Text("The default model is used when a RxCode Agent chat does not pick one.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.displayName)
    }
}
