import RxCodeCore
import SwiftUI

// MARK: - Hugging Face Text-to-Speech Catalog

/// Searches Hugging Face text-to-speech models. Each row shows the download
/// size and how it fits this Mac; clicking a row opens the same README,
/// metadata and per-variant download detail the Local Models window uses.
struct PetVoiceCatalogView: View {
    private static let recommendedRepos: [(repoID: String, format: LocalModelWeightFormat, note: String)] = [
        ("mlx-community/Kokoro-82M-bf16", .mlx, "Fast, expressive 82M neural TTS optimized for Apple Silicon MLX"),
        ("mlx-community/Kokoro-82M-4bit", .mlx, "Ultra-compact 4-bit Kokoro neural TTS for low memory footprint"),
    ]

    private struct PendingDownload: Identifiable {
        let summary: HFModelSummary
        let variant: HFModelVariant
        var id: String { "\(summary.id)/\(variant.id)" }
    }

    @Bindable var controller: PetController
    @Binding var actionOverlayMessage: String?
    @Binding var errorMessage: String?
    @Environment(AppState.self) private var appState

    @State private var browseFormat: LocalModelWeightFormat = .mlx
    @State private var searchQuery = ""
    @State private var searchResults: [HFModelSummary] = []
    @State private var variantsByRepo: [String: [HFModelVariant]] = [:]
    @State private var isSearching = false
    @State private var detailSummary: HFModelSummary?
    @State private var pendingLargeDownload: PendingDownload?

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Format", selection: $browseFormat) {
                    Text("MLX (Apple Silicon)").tag(LocalModelWeightFormat.mlx)
                    Text("GGUF (llama.cpp)").tag(LocalModelWeightFormat.gguf)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                TextField("Search Hugging Face text-to-speech models (e.g. Kokoro)…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await performSearch() } }

                Button {
                    Task { await performSearch() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(isSearching)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: browseFormat) { await performSearch() }
        .sheet(item: $detailSummary) { summary in
            PetVoiceModelDetailSheet(summary: summary) { summary, variant in
                requestDownload(summary: summary, variant: variant)
            }
            .environment(appState)
        }
        .alert(
            "Download Large Voice Model?",
            isPresented: Binding(
                get: { pendingLargeDownload != nil },
                set: { if !$0 { pendingLargeDownload = nil } }
            ),
            presenting: pendingLargeDownload
        ) { pending in
            Button("Cancel", role: .cancel) { pendingLargeDownload = nil }
            Button("Download Anyway") {
                pendingLargeDownload = nil
                Task { await startDownload(summary: pending.summary, variant: pending.variant) }
            }
        } message: { pending in
            Text("This model is \(LocalModelFormat.bytes(pending.variant.sizeBytes)) and may use a large share of unified GPU memory on this Mac.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching && searchResults.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching Hugging Face text-to-speech catalog…")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            ContentUnavailableView {
                Label("No Voice Models Found", systemImage: "waveform.slash")
            } description: {
                Text("Try another search term such as “Kokoro” or switch between MLX and GGUF formats.")
            } actions: {
                Button("Reset Search") {
                    searchQuery = ""
                    Task { await performSearch() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && browseFormat == .mlx {
                    Section("Recommended for RxBuddy") {
                        ForEach(Self.recommendedRepos, id: \.repoID) { rec in
                            recommendedRow(rec)
                        }
                    }
                }

                Section {
                    ForEach(searchResults) { summary in
                        catalogModelRow(summary)
                    }
                } header: {
                    Text("Hugging Face Text-to-Speech Models")
                } footer: {
                    Text("Click a model to read its README and choose a download. After download, the setup agent reads the README to build the model's voice settings.")
                }
            }
        }
    }

    // MARK: - Rows

    private func recommendedRow(_ rec: (repoID: String, format: LocalModelWeightFormat, note: String)) -> some View {
        let alreadyInstalled = store.installed.first { $0.repoID == rec.repoID && $0.format == rec.format }
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(ClaudeTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.repoID)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text(rec.note)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let installed = alreadyInstalled {
                let isActive = controller.configuration.usesLocalVoice(modelID: installed.id)
                Button(isActive ? "Active" : "Use Voice") {
                    PetVoicePresets.select(model: installed, in: &controller.configuration)
                }
                .disabled(isActive)
                .controlSize(.small)
            } else {
                Button("Details") {
                    Task { await openDetail(repoID: rec.repoID, format: rec.format) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openDetail(repoID: rec.repoID, format: rec.format) }
        }
    }

    private func catalogModelRow(_ summary: HFModelSummary) -> some View {
        let variants = variantsByRepo[summary.id]
        let installed = store.installed.contains { $0.repoID == summary.id && $0.format == summary.format }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.id)
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HFAccessBadge(summary: summary)
                }
                HStack(spacing: 10) {
                    if let params = LocalModelFormat.parameters(summary.parameterCount) { Text(params) }
                    Label(summary.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                    Label(summary.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                    Text(summary.format.label)
                }
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
            }
            Spacer()
            sizeBadge(variants)
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { detailSummary = summary }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { detailSummary = summary }
        .task { await loadVariants(for: summary) }
    }

    @ViewBuilder
    private func sizeBadge(_ variants: [HFModelVariant]?) -> some View {
        if let variants {
            let sizes = variants.map(\.sizeBytes).filter { $0 > 0 }
            if let smallest = sizes.min(), let largest = sizes.max() {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(smallest == largest
                         ? LocalModelFormat.bytes(smallest)
                         : "\(LocalModelFormat.bytes(smallest)) – \(LocalModelFormat.bytes(largest))")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .monospacedDigit()
                    LocalModelFitBadge(fit: store.fit(bytes: smallest))
                        .font(.system(size: ClaudeTheme.size(10)))
                }
            } else {
                Text("No \(variants.isEmpty ? "files" : "size")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    // MARK: - Actions

    private func performSearch() async {
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await HuggingFaceClient.search(
                searchQuery,
                format: browseFormat,
                category: "text-to-speech",
                limit: 25
            )
            searchResults = page.models
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sizes come from the repo's file tree; failures leave the row without a size.
    private func loadVariants(for summary: HFModelSummary) async {
        guard variantsByRepo[summary.id] == nil else { return }
        if let variants = try? await HuggingFaceClient.variants(of: summary) {
            variantsByRepo[summary.id] = variants
        }
    }

    private func openDetail(repoID: String, format: LocalModelWeightFormat) async {
        actionOverlayMessage = "Loading \(repoID)…"
        defer { actionOverlayMessage = nil }
        do {
            detailSummary = try await HuggingFaceClient.model(repoID, format: format)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestDownload(summary: HFModelSummary, variant: HFModelVariant) {
        if store.fit(bytes: variant.sizeBytes).needsWarning {
            pendingLargeDownload = PendingDownload(summary: summary, variant: variant)
        } else {
            Task { await startDownload(summary: summary, variant: variant) }
        }
    }

    private func startDownload(summary: HFModelSummary, variant: HFModelVariant) async {
        do {
            if store.runtime(for: summary.format) == nil {
                actionOverlayMessage = "Installing \(summary.format.runtimeName) runtime…"
                try await store.installRuntime(for: summary.format)
                actionOverlayMessage = nil
            }
            try await store.download(summary: summary, variant: variant)
            if let installed = store.installed.first(where: { $0.repoID == summary.id && $0.format == summary.format }) {
                PetVoicePresets.select(model: installed, in: &controller.configuration)
            }
        } catch is CancellationError {
            actionOverlayMessage = nil
        } catch {
            actionOverlayMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Model Detail Sheet

/// The Local Models window's detail view (README, metadata, per-variant
/// sizes and fit) as a full-height sheet.
private struct PetVoiceModelDetailSheet: View {
    let summary: HFModelSummary
    let onDownload: (HFModelSummary, HFModelVariant) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LocalModelDetailView(summary: summary) { summary, variant in
                onDownload(summary, variant)
                dismiss()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: .infinity,
               minHeight: 600, idealHeight: 720, maxHeight: .infinity)
    }
}
