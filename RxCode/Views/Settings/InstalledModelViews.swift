import AppKit
import RxCodeCore
import SwiftUI

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

struct InstalledModelRow: View {
    let model: LocalModelInfo
    let companions: [LocalCompanionFile]
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
                        .foregroundStyle(ClaudeTheme.accentText)
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
            if !companions.isEmpty {
                Label(
                    "\(companions.count) companion file\(companions.count == 1 ? "" : "s") · \(LocalModelFormat.bytes(companions.reduce(0) { $0 + $1.sizeBytes }))",
                    systemImage: "puzzlepiece.extension"
                )
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An installed model's details and the actions that change it, beside its
/// model card. The toolbar opens the repo's full Hugging Face page, where
/// other quantizations can be downloaded.
struct InstalledModelDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details"
        case readme = "README"
        var id: String { rawValue }
    }

    let model: LocalModelInfo
    let companions: [LocalCompanionFile]
    let directory: URL
    let isDefault: Bool
    let fit: LocalModelFit
    let onChat: () -> Void
    let onMakeDefault: () -> Void
    let onDelete: () -> Void
    let onDownload: (HFModelSummary, HFModelVariant) -> Void

    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .details
    @State private var loadingPage = false
    @State private var pageError: String?
    @State private var page: HFModelSummary?

    var body: some View {
        Group {
            switch tab {
            case .details: details
            case .readme: InstalledModelCardView(model: model, modelsRoot: appState.localModels.modelsRoot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 10)
                ClaudeThemeDivider()
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(model.displayName)
        .navigationDestination(item: $page) { summary in
            LocalModelDetailView(summary: summary, onDownload: onDownload)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Model Page", systemImage: "cube.transparent") { openModelPage() }
                    .help("Open this model's Hugging Face page and downloads")
                    .disabled(loadingPage)
                    .accessibilityIdentifier("local-model-open-page")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Chat with Model", systemImage: "bubble.left.and.bubble.right", action: onChat)
                    .help("Open a new chat with this model selected")
                    .accessibilityIdentifier("local-model-start-chat")
            }
        }
        .overlay {
            if loadingPage {
                ProgressView("Loading model page…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Couldn't Open the Model Page", isPresented: Binding(
            get: { pageError != nil }, set: { if !$0 { pageError = nil } }
        )) {
            Button("OK", role: .cancel) { pageError = nil }
        } message: {
            Text(pageError ?? "")
        }
    }

    /// The saved Hugging Face metadata when the model has it; models saved
    /// before it was recorded look the repo up.
    private func openModelPage() {
        if let saved = model.huggingFaceMetadata {
            page = saved
            return
        }
        loadingPage = true
        Task {
            defer { loadingPage = false }
            do {
                page = try await HuggingFaceClient.model(model.repoID, format: model.format)
            } catch {
                pageError = error.localizedDescription
            }
        }
    }

    private var details: some View {
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
                if !companions.isEmpty {
                    LabeledContent(
                        "Total with companions",
                        value: LocalModelFormat.bytes(companions.reduce(model.sizeBytes) { $0 + $1.sizeBytes })
                    )
                }
            }
            if !companions.isEmpty {
                SwiftUI.Section {
                    ForEach(companions) { companion in
                        LabeledContent {
                            Text(LocalModelFormat.bytes(companion.sizeBytes))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(companion.localName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text([companion.role, companion.repoID].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: ClaudeTheme.size(10)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([directory.appending(path: companion.localName)])
                            }
                        }
                    }
                } header: {
                    Text("Companion Files")
                } footer: {
                    Text("Text encoders, VAEs and other files downloaded so this model can generate. Deleting the model removes them.")
                }
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
    }
}
