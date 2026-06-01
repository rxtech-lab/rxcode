import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Documentation management: docs-indexed repositories, their documents, and CI
/// upload-token / GitHub-secret setup.
struct MobileDocsView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var repos: [DocsRepo] = []
    @State private var search = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var pendingDelete: DocsRepo?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(repos) { repo in
                NavigationLink {
                    MobileDocsRepoDetailView(repo: repo)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.repositoryFullName)
                        if let count = repo.documentsCount {
                            Text("\(count) document(s)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingDelete = repo }
                }
            }
            if repos.isEmpty, !isLoading {
                Text("No documentation repositories. Tap + to add one.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Documentation")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .onChange(of: search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            MobileAutopilotRepoPicker(
                title: "Add Docs Repository",
                existingRepoFullNames: Set(repos.map { $0.repositoryFullName.lowercased() })
            ) { repo in
                await add(repo)
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .alert(
            "Remove repository?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let repo = pendingDelete { Task { await delete(repo) } }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the repository and its indexed documents from docs search.")
        }
        .mobileAutopilotLoadingOverlay(isLoading && repos.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repos = try await state.listDocsRepos(search: search).items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ repo: SecretsManagedRepo) async {
        do {
            try await state.addDocsRepo(AddDocsRepoBody(
                installationId: repo.installationId,
                repositoryId: repo.id,
                repositoryFullName: repo.fullName
            ))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ repo: DocsRepo) async {
        do {
            try await state.deleteDocsRepo(id: repo.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileDocsRepoDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    let repo: DocsRepo

    @State private var documents: [DocsDocument] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isInstallingSecret = false
    @State private var showingAddDocument = false
    @State private var viewingDocument: DocsDocument?
    @State private var pendingDelete: DocsDocument?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
            }

            Section {
                Button {
                    Task { await installSecret() }
                } label: {
                    if isInstallingSecret {
                        HStack { ProgressView(); Text("Installing…") }
                    } else {
                        Label("Install CI upload token", systemImage: "key.horizontal")
                    }
                }
                .disabled(isInstallingSecret)
            } header: {
                Text("CI")
            } footer: {
                Text("Mints a DOCS_UPLOAD_TOKEN and installs it as the repo's GitHub Actions secret so CI can publish docs automatically.")
            }

            Section("Documents") {
                if documents.isEmpty, !isLoading {
                    Text("No documents indexed yet.").foregroundStyle(.secondary)
                }
                ForEach(documents) { doc in
                    Button {
                        viewingDocument = doc
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title ?? doc.docId).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(doc.docId).font(.caption).foregroundStyle(.secondary)
                                if let status = doc.embeddingStatus {
                                    Text(status).font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = doc }
                    }
                }
            }
        }
        .navigationTitle(repo.repositoryFullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddDocument = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAddDocument) {
            MobileDocsUploadView(repoId: repo.id) { await reload() }
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .sheet(item: $viewingDocument) { doc in
            MobileDocumentView(repoId: repo.id, docId: doc.docId)
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .alert(
            "Delete document?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let doc = pendingDelete { Task { await delete(doc) } }
                pendingDelete = nil
            }
        }
        .mobileAutopilotLoadingOverlay(isLoading && documents.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            documents = try await state.listDocuments(repoId: repo.id).items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSecret() async {
        isInstallingSecret = true
        statusMessage = nil
        errorMessage = nil
        defer { isInstallingSecret = false }
        do {
            let result = try await state.installDocsGithubSecret(repoId: repo.id)
            statusMessage = "Installed \(result.secretName)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ doc: DocsDocument) async {
        do {
            try await state.deleteDocument(repoId: repo.id, docId: doc.docId)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Read-only markdown view of a single document's current version.
struct MobileDocumentView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repoId: String
    let docId: String

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).padding()
                } else if !isLoading {
                    MarkdownContentView(text: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(docId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .mobileAutopilotLoadingOverlay(isLoading)
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await state.getDocument(repoId: repoId, docId: docId)
            content = detail.currentVersion?.content ?? "(no content)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Upload (create/update) a document by pasting markdown.
struct MobileDocsUploadView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repoId: String
    let onUploaded: () async -> Void

    @State private var docId = ""
    @State private var content = ""
    @State private var originalLink = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Document ID (slug)") {
                    TextField("design/overview", text: $docId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Source link (optional)") {
                    TextField("https://…", text: $originalLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Markdown") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { Task { await upload() } }
                        .disabled(isSaving || docId.trimmingCharacters(in: .whitespaces).isEmpty || content.isEmpty)
                }
            }
        }
    }

    private func upload() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let link = originalLink.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await state.uploadDocument(
                repoId: repoId,
                docId: docId.trimmingCharacters(in: .whitespacesAndNewlines),
                content: content,
                originalLink: link.isEmpty ? nil : link
            )
            await onUploaded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
