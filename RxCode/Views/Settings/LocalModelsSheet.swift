import RxCodeCore
import SwiftUI

/// Browse, download and manage the local models the RxCode Agent runs.
///
/// Two sections behind a segmented control — the Hugging Face catalog, fetched
/// on demand, and what is installed — so each is its own full-height list.
/// Choosing a quantization for a search result is its own pushed view.
struct LocalModelsSheet: View {
    enum Section: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case mine = "My Models"
        case installed = "Installed"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .browse
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var pendingDownload: PendingDownload?
    @State private var pendingDeletion: LocalModelInfo?
    @State private var showSignIn = false

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hardwareHeader
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 10)
                Divider()
                Group {
                    switch section {
                    case .browse: LocalModelBrowseView(onDownload: requestDownload)
                    case .mine: myModels
                    case .installed: installedList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Local Models")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HuggingFaceAccountButton(showSignIn: $showSignIn)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: HFModelSummary.self) { summary in
                LocalModelDetailView(summary: summary, onDownload: requestDownload)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { progressOverlay }
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

    // MARK: - Header

    private var hardwareHeader: some View {
        HStack(alignment: .center, spacing: 16) {
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
            Spacer()
            serverControls
            runtimeControls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Runtimes install on demand with the first download of their format,
    /// so the header only reports what is already installed.
    @ViewBuilder
    private var runtimeControls: some View {
        if let runtime = store.mlxRuntime {
            Label("MLX \(runtime.version)", systemImage: "checkmark.circle.fill")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.statusSuccess)
        }
        if let runtime = store.runtime {
            Label("llama.cpp \(runtime.version)", systemImage: "checkmark.circle.fill")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.statusSuccess)
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
            LocalModelBrowseView(author: account.username, onDownload: requestDownload)
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

    @ViewBuilder
    private var installedList: some View {
        if store.installed.isEmpty {
            ContentUnavailableView(
                "No Local Models",
                systemImage: "shippingbox",
                description: Text("Download a model from Browse to use the RxCode Agent.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            @Bindable var store = store
            Form {
                SwiftUI.Section("Models") {
                    ForEach(store.installed) { model in
                        InstalledModelRow(
                            model: model,
                            isDefault: store.settings.defaultModelID == model.id,
                            fit: store.fit(bytes: model.sizeBytes),
                            onMakeDefault: { store.settings.defaultModelID = model.id },
                            onDelete: { pendingDeletion = model }
                        )
                    }
                }
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
        }
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
                        isPrivate: summary.isPrivate, isGated: summary.isGated
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
    let onMakeDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    if isDefault {
                        Text("Default")
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accent)
                    }
                }
                HStack(spacing: 10) {
                    Text("by \(model.author)")
                    if let params = LocalModelFormat.parameters(model.parameterCount) { Text("\(params) parameters") }
                    Text(LocalModelFormat.bytes(model.sizeBytes))
                    if let context = model.contextLength { Text("\(context.formatted()) max context") }
                    LocalModelFitBadge(fit: fit)
                }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Manage…") {
                Button("Make Default", action: onMakeDefault).disabled(isDefault)
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
            .fixedSize()
            .controlSize(.small)
        }
    }
}

