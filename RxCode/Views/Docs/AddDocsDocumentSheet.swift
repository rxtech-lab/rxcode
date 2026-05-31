import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Form to upload a single document to a docs repository. Mirrors the CI
/// uploader's contract: a `docId` slug (unique within the repo), the markdown
/// `content`, and an optional canonical `originalLink`. Content can be typed or
/// loaded from a local markdown file.
struct AddDocsDocumentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Internal docs-repo UUID or `owner/repo` — both are accepted by the API.
    let repoId: String
    var onUploaded: () -> Void

    @State private var docId = ""
    @State private var originalLink = ""
    @State private var content = ""
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var showImporter = false

    private var trimmedDocId: String { docId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        !trimmedDocId.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isUploading
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    TextField("Slug (e.g. architecture/overview)", text: $docId)
                    TextField("Original link (optional)", text: $originalLink)
                        .textContentType(.URL)
                }
                Section {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                } header: {
                    HStack {
                        Text("Markdown content")
                        Spacer()
                        Button("Load from File…") { showImporter = true }
                            .font(.caption)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Document")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await upload() }
                    } label: {
                        if isUploading { ProgressView().controlSize(.small) } else { Text("Upload") }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .frame(width: 560, height: 560)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: markdownTypes) { result in
            handleImport(result)
        }
    }

    private var markdownTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        return types
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                content = try String(contentsOf: url, encoding: .utf8)
                if trimmedDocId.isEmpty {
                    docId = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func upload() async {
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        let link = originalLink.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await appState.docs.uploadDocuments(
                repoId: repoId,
                documents: [
                    DocsDocumentUpload(
                        docId: trimmedDocId,
                        content: content,
                        originalLink: link.isEmpty ? nil : link
                    )
                ]
            )
            onUploaded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
