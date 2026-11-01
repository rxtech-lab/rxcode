import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Browse

/// Hugging Face search, shown as the split view's sidebar list. Pages load on
/// demand as the list scrolls to its end; selecting a result shows its
/// quantizations in the detail column.
///
/// With an `author`, lists that account's repos instead of the whole catalog —
/// for the signed-in user, private ones included.
struct LocalModelBrowseView: View {
    @Environment(AppState.self) private var appState
    var author: String?
    @Binding var selection: HFModelSummary?

    @State private var query = ""
    /// MLX is native to Apple silicon; Intel Macs only run GGUF.
    @State private var format: LocalModelWeightFormat = LlamaRuntimeInstaller.isAppleSilicon ? .mlx : .gguf
    @State private var category = ""
    @State private var categories: [HuggingFaceClient.Category] = []
    @State private var categoryError: String?
    @State private var searchID = UUID()
    @State private var results: [HFModelSummary] = []
    @State private var nextPage: URL?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var loadMoreError: String?

    init(author: String? = nil, selection: Binding<HFModelSummary?>, initialModel: LocalModelSheetRequest? = nil) {
        self.author = author
        self._selection = selection
        self._query = State(initialValue: initialModel?.repoID ?? "")
        self._format = State(initialValue: initialModel?.format ?? (LlamaRuntimeInstaller.isAppleSilicon ? .mlx : .gguf))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(author == nil ? "Search \(format.label) models" : "Search your \(format.label) models",
                              text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await search() } }
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Menu {
                        Picker("Format", selection: $format) {
                            ForEach(LocalModelWeightFormat.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Label(format.label, systemImage: "cpu")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .help("GGUF models run on llama.cpp; MLX models run on Apple's MLX.")

                    Menu {
                        Picker("Category", selection: $category) {
                            Text("All Categories").tag("")
                            ForEach(categories) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        if categoryError != nil {
                            Button("Retry Loading Categories") { Task { await loadCategories() } }
                        } else if categories.isEmpty {
                            Text("Loading Categories…")
                        }
                    } label: {
                        Label(categoryLabel, systemImage: "line.3.horizontal.decrease")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .help(categoryError ?? "Filter by Hugging Face task category.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let errorMessage {
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !loading {
                if author != nil && query.isEmpty && category.isEmpty {
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
                        row(summary)
                            .selectableModelRow(isSelected: selection?.id == summary.id) { selection = summary }
                    }
                    if nextPage != nil { pageFooter }
                }
            }
        }
        .task { await loadCategories() }
        .task(id: searchKey) { await search() }
        .onChange(of: searchKey) { selection = nil }
    }

    private var categoryLabel: String {
        categories.first { $0.id == category }?.label ?? "All Categories"
    }

    private var searchKey: SearchKey { SearchKey(format: format, author: author, category: category) }

    private func loadCategories() async {
        do {
            categories = try await HuggingFaceClient.categories()
            categoryError = nil
        } catch {
            categoryError = error.localizedDescription
        }
    }

    private struct SearchKey: Hashable {
        let format: LocalModelWeightFormat
        let author: String?
        let category: String
    }

    private func row(_ summary: HFModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(summary.name)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HFAccessBadge(summary: summary)
            }
            HStack(spacing: 8) {
                Text(summary.author).lineLimit(1)
                if let params = LocalModelFormat.parameters(summary.parameterCount) { Text(params) }
                Spacer(minLength: 0)
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
        let requestID = UUID()
        searchID = requestID
        loadingMore = false
        nextPage = nil
        results = []
        loading = true
        errorMessage = nil
        loadMoreError = nil
        defer { if searchID == requestID { loading = false } }
        do {
            let page = try await HuggingFaceClient.search(query, format: format, author: author, category: category.isEmpty ? nil : category)
            guard searchID == requestID, !Task.isCancelled else { return }
            results = page.models
            nextPage = page.next
        } catch is CancellationError {
            return
        } catch {
            guard searchID == requestID, !Task.isCancelled else { return }
            results = []
            nextPage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let url = nextPage, !loadingMore, !loading else { return }
        loadingMore = true
        loadMoreError = nil
        let requestID = searchID
        defer { if searchID == requestID { loadingMore = false } }
        let requestedKey = searchKey
        let requestedFormat = format
        do {
            let page = try await HuggingFaceClient.page(at: url, format: requestedFormat)
            // A search or format change while this page loaded replaced the list.
            guard searchID == requestID, searchKey == requestedKey, nextPage == url else { return }
            let known = Set(results.map(\.id))
            results += page.models.filter { !known.contains($0.id) }
            nextPage = page.next
        } catch {
            guard searchID == requestID, searchKey == requestedKey else { return }
            loadMoreError = error.localizedDescription
        }
    }
}

/// One repo, in two tabs: its Hugging Face model card, and its downloadable
/// variants, each with its size and how it fits this Mac.
struct LocalModelDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case readme = "README"
        case downloads = "Downloads"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    let summary: HFModelSummary
    let onDownload: (HFModelSummary, HFModelVariant) -> Void

    @State private var tab: Tab = .readme
    @State private var variants: [HFModelVariant] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var card: String?
    @State private var cardLoading = true
    @State private var cardError: String?

    private var store: LocalModelStore { appState.localModels }
    private var repoURL: URL { HuggingFaceClient.base.appending(path: summary.id) }

    var body: some View {
        List {
            switch tab {
            case .readme:
                SwiftUI.Section {
                    metadataCard
                }
                SwiftUI.Section {
                    modelCard
                }
            case .downloads:
                SwiftUI.Section {
                    downloads
                } header: {
                    header
                } footer: {
                    downloadsFooter
                }
            }
        }
        // A sheet has no title bar to host a principal toolbar item, so the
        // tab switch sits above the list instead.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 10)
                Divider()
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(summary.name)
        .task { await load() }
        .task { await loadCard() }
    }

    private var header: some View {
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
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(summary.author).foregroundStyle(.secondary)
                }
                Spacer()
                HFAccessBadge(summary: summary)
                Link(destination: repoURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open on Hugging Face")
                .accessibilityLabel("Open on Hugging Face")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 14) {
                metadataField("Category", value: summary.categoryLabel ?? String(localized: "Not specified"))
                metadataField("Format", value: summary.format.label)
                if let library = summary.libraryName { metadataField("Library", value: library) }
                if !summary.licenses.isEmpty { metadataField("License", value: summary.licenses.joined(separator: ", ")) }
                if let params = LocalModelFormat.parameters(summary.parameterCount) { metadataField("Parameters", value: params) }
                if let size = sizeSummary { metadataField("Size", value: size) }
                if let context = summary.contextLength { metadataField("Context", value: context.formatted()) }
                if let architecture = summary.architecture { metadataField("Architecture", value: architecture) }
                metadataField("Downloads", value: summary.downloads.formatted())
                metadataField("Likes", value: summary.likes.formatted())
                if let date = summary.lastModified { metadataField("Updated", value: date.formatted(date: .abbreviated, time: .omitted)) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .padding(.vertical, 6)
    }

    /// Download size from the repo's variants: one size for a single variant,
    /// otherwise the range across quantizations. Nil when there is nothing to show.
    private var sizeSummary: String? {
        if loading { return String(localized: "Loading…") }
        let sizes = variants.map(\.sizeBytes).filter { $0 > 0 }
        guard let smallest = sizes.min(), let largest = sizes.max() else { return nil }
        if smallest == largest { return LocalModelFormat.bytes(smallest) }
        return String(localized: "\(LocalModelFormat.bytes(smallest)) – \(LocalModelFormat.bytes(largest)) (\(sizes.count) variants)")
    }

    private func metadataField(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The repo's `README.md`. Relative links and images resolve against the repo's files.
    @ViewBuilder
    private var modelCard: some View {
        if cardLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading model card…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else if let card {
            MarkdownContentView(text: card, baseURL: repoURL.appending(path: "resolve/main/"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            HStack(spacing: 6) {
                Text(cardError ?? String(localized: "This repository has no model card."))
                    .foregroundStyle(.secondary)
                Link("Open on Hugging Face", destination: repoURL)
            }
            .font(.system(size: ClaudeTheme.size(11)))
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var downloads: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading files…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else if variants.isEmpty {
            Text("This repository has no downloadable \(summary.format.label) model files.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ForEach(variants) { variant in
                variantRow(variant)
            }
        }
    }

    @ViewBuilder
    private var downloadsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.isGated {
                Text("This model is gated: request access on its [Hugging Face page](\(repoURL.absoluteString)), then download it while signed in.")
            }
            switch summary.format {
            case .gguf:
                Text("Smaller quantizations (Q4) use less memory with a small quality cost. Q4_K_M is a good default.")
            case .mlx:
                Text("MLX repositories hold one quantization and download whole. Text models run natively on Apple silicon using the MLX Swift runtime included with RxCode. No Python installation is needed.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

    private func loadCard() async {
        cardLoading = true
        defer { cardLoading = false }
        do {
            card = try await HuggingFaceClient.modelCard(of: summary.id)
        } catch is CancellationError {
            return
        } catch {
            cardError = error.localizedDescription
        }
    }
}


/// Sidebar selection drawn by the app rather than the system list highlight,
/// whose accent-coloured fill can leave the row's text unreadable.
private struct SelectableModelRow: ViewModifier {
    let isSelected: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? ClaudeTheme.accent.opacity(0.22) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    func selectableModelRow(isSelected: Bool, action: @escaping () -> Void) -> some View {
        modifier(SelectableModelRow(isSelected: isSelected, action: action))
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

/// An installed model's card: the README downloaded with it, else the repo's
/// current one. Relative links and images resolve against the repo's files.
struct InstalledModelCardView: View {
    let model: LocalModelInfo
    let modelsRoot: URL

    @State private var card: String?
    @State private var loading = true
    @State private var errorMessage: String?

    private var repoURL: URL { HuggingFaceClient.base.appending(path: model.repoID) }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading model card…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let card {
                List {
                    MarkdownContentView(text: card, baseURL: repoURL.appending(path: "resolve/main/"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView {
                    Label("No Model Card", systemImage: "doc.text")
                } description: {
                    Text(errorMessage ?? String(localized: "This repository has no model card."))
                } actions: {
                    Link("Open on Hugging Face", destination: repoURL)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.id) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            card = try await LocalModelCard.load(model, modelsRoot: modelsRoot)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
