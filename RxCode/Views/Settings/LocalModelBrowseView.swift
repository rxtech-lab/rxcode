import RxCodeCore
import SwiftUI

// MARK: - Browse

/// Hugging Face search. Pages load on demand as the list scrolls to its end;
/// results push a detail view to pick a quantization.
///
/// With an `author`, lists that account's repos instead of the whole catalog —
/// for the signed-in user, private ones included.
struct LocalModelBrowseView: View {
    @Environment(AppState.self) private var appState
    var author: String?
    let onDownload: (HFModelSummary, HFModelVariant) -> Void

    @State private var query = ""
    /// MLX is native to Apple silicon; Intel Macs only run GGUF.
    @State private var format: LocalModelWeightFormat = LlamaRuntimeInstaller.isAppleSilicon ? .mlx : .gguf
    @State private var results: [HFModelSummary] = []
    @State private var nextPage: URL?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var loadMoreError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(author == nil ? "Search \(format.label) models on Hugging Face" : "Search your \(format.label) models",
                              text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await search() } }
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Picker("Format", selection: $format) {
                    ForEach(LocalModelWeightFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("GGUF models run on llama.cpp; MLX models run on Apple's MLX.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let errorMessage {
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !loading {
                if author != nil && query.isEmpty {
                    ContentUnavailableView(
                        "No \(format.label) Models", systemImage: "person.crop.square",
                        description: Text("\(format.label) models you upload to Hugging Face, including private ones, appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(results) { summary in
                        NavigationLink(value: summary) { row(summary) }
                    }
                    if nextPage != nil { pageFooter }
                }
            }
        }
        .task(id: SearchKey(format: format, author: author)) { await search() }
    }

    private struct SearchKey: Hashable {
        let format: LocalModelWeightFormat
        let author: String?
    }

    private func row(_ summary: HFModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(summary.name).font(.system(size: ClaudeTheme.size(12), weight: .medium))
                HFAccessBadge(summary: summary)
            }
            HStack(spacing: 10) {
                Text("by \(summary.author)")
                if let params = LocalModelFormat.parameters(summary.parameterCount) { Text("\(params) parameters") }
                if let context = summary.contextLength { Text("\(context.formatted()) context") }
                Label(summary.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                Label(summary.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
            }
            .font(.system(size: ClaudeTheme.size(10)))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Appears when the list reaches its end, which is what fetches the next page.
    @ViewBuilder
    private var pageFooter: some View {
        HStack {
            Spacer()
            if let loadMoreError {
                VStack(spacing: 6) {
                    Text(loadMoreError)
                        .font(.system(size: ClaudeTheme.size(10)))
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadMore() } }
                        .controlSize(.small)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .onAppear { Task { await loadMore() } }
    }

    private func search() async {
        loading = true
        errorMessage = nil
        loadMoreError = nil
        defer { loading = false }
        do {
            let page = try await HuggingFaceClient.search(query, format: format, author: author)
            results = page.models
            nextPage = page.next
        } catch is CancellationError {
            return
        } catch {
            results = []
            nextPage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let url = nextPage, !loadingMore, !loading else { return }
        loadingMore = true
        loadMoreError = nil
        defer { loadingMore = false }
        let requestedFormat = format
        do {
            let page = try await HuggingFaceClient.page(at: url, format: requestedFormat)
            // A search or format change while this page loaded replaced the list.
            guard nextPage == url, format == requestedFormat else { return }
            let known = Set(results.map(\.id))
            results += page.models.filter { !known.contains($0.id) }
            nextPage = page.next
        } catch {
            loadMoreError = error.localizedDescription
        }
    }
}

/// One repo's downloadable variants, each with its size and how it fits this Mac.
struct LocalModelDetailView: View {
    @Environment(AppState.self) private var appState
    let summary: HFModelSummary
    let onDownload: (HFModelSummary, HFModelVariant) -> Void

    @State private var variants: [HFModelVariant] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private var store: LocalModelStore { appState.localModels }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Could Not Load Files", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if variants.isEmpty {
                ContentUnavailableView(
                    "No \(summary.format.label) Files", systemImage: "doc",
                    description: Text("This repository has no downloadable \(summary.format.label) model files.")
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    SwiftUI.Section {
                        ForEach(variants) { variant in
                            variantRow(variant)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("by \(summary.author)")
                                HFAccessBadge(summary: summary)
                            }
                            HStack(spacing: 10) {
                                if let params = LocalModelFormat.parameters(summary.parameterCount) { Text("\(params) parameters") }
                                if let context = summary.contextLength { Text("\(context.formatted()) context") }
                                if let architecture = summary.architecture { Text(architecture) }
                            }
                        }
                    } footer: {
                        if summary.isGated {
                            Text("This model is gated: request access on its [Hugging Face page](\(HuggingFaceClient.base.appending(path: summary.id).absoluteString)), then download it while signed in.")
                        }
                        switch summary.format {
                        case .gguf:
                            Text("Smaller quantizations (Q4) use less memory with a small quality cost. Q4_K_M is a good default.")
                        case .mlx:
                            Text("MLX repositories hold one quantization and download whole. Text models run natively on Apple silicon using the MLX Swift runtime included with RxCode. No Python installation is needed.")
                        }
                    }
                }
            }
        }
        .navigationTitle(summary.name)
        .task { await load() }
    }

    private func variantRow(_ variant: HFModelVariant) -> some View {
        let key = "\(summary.id)/\(variant.id)"
        let installed = store.isInstalled(summary: summary, variant: variant)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.format == .mlx ? (variant.quantization ?? summary.name) : variant.displayName)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                HStack(spacing: 10) {
                    Text(LocalModelFormat.bytes(variant.sizeBytes))
                    if summary.format == .mlx {
                        Text("\(variant.files.count) files")
                    } else if variant.files.count > 1 {
                        Text("\(variant.files.count) parts")
                    }
                    LocalModelFitBadge(fit: store.fit(bytes: variant.sizeBytes))
                }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Label("Installed", systemImage: "checkmark")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            } else if store.downloads[key] != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { onDownload(summary, variant) }
                    .controlSize(.small)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            variants = try await HuggingFaceClient.variants(of: summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Marks repos that need a signed-in Hugging Face account to download.
struct HFAccessBadge: View {
    let summary: HFModelSummary

    var body: some View {
        if summary.isPrivate {
            Label("Private", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(.secondary)
                .help("Only visible to its owner")
        } else if summary.isGated {
            Label("Gated", systemImage: "key.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(ClaudeTheme.statusWarning)
                .help("Requires accepting the model's terms on Hugging Face")
        }
    }
}
