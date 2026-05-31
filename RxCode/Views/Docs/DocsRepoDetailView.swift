import AppKit
import RxCodeCore
import SwiftUI

/// Detail for one docs repository: lists its documents and lets the user
/// install a `DOCS_UPLOAD_TOKEN` GitHub Actions secret in one click — RxCode
/// mints the token and stores it on the repo server-side. Mirrors
/// `SecretsRepoDetailView`.
struct DocsRepoDetailView: View {
    let repo: DocsRepo
    var onClose: () -> Void

    @Environment(AppState.self) private var appState

    @State private var documents: [DocsDocument] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var isInstallingSecret = false
    @State private var installedSecret: DocsGithubSecretResult?
    @State private var installError: String?

    @State private var showDeleteConfirm = false
    @State private var showAddDocument = false
    @State private var documentToDelete: DocsDocument?
    @State private var selectedDocument: DocsDocument?

    var body: some View {
        List {
            tokenSection
            documentsSection
            dangerSection
        }
        .navigationTitle(repo.repositoryFullName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddDocument = true
                } label: {
                    Label("Add Document", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onClose() }
            }
        }
        .task { await loadDocuments() }
        .sheet(isPresented: $showAddDocument) {
            AddDocsDocumentSheet(repoId: repo.id, onUploaded: { Task { await loadDocuments() } })
                .environment(appState)
        }
        .sheet(item: $selectedDocument) { doc in
            DocsDocumentDetailView(
                repoId: repo.id,
                docId: doc.docId,
                fallbackTitle: doc.title ?? doc.docId,
                fallbackContent: nil,
                originalLink: nil
            )
            .environment(appState)
        }
        .alert("Remove this docs repository?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) { Task { await deleteRepo() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unregisters \(repo.repositoryFullName) from the docs service and removes its indexed documents. The repo's files are not affected.")
        }
        .alert("Delete this document?", isPresented: deleteDocumentBinding) {
            Button("Delete", role: .destructive) {
                if let doc = documentToDelete { Task { await deleteDocument(doc) } }
            }
            Button("Cancel", role: .cancel) { documentToDelete = nil }
        } message: {
            Text("\(documentToDelete?.docId ?? "This document") will be removed from the docs index. This can't be undone.")
        }
    }

    private var deleteDocumentBinding: Binding<Bool> {
        Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )
    }

    // MARK: - Upload token

    @ViewBuilder
    private var tokenSection: some View {
        Section("CI upload token") {
            Text("Install a DOCS_UPLOAD_TOKEN secret so this repo's CI can upload docs. RxCode mints the token and stores it as the repository's GitHub Actions secret for you — no terminal needed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let installed = installedSecret {
                Label("Installed \(installed.secretName) on \(installed.repositoryFullName)", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if let installError {
                Text(installError).foregroundStyle(.red).font(.caption)
            }

            Button {
                Task { await installSecret() }
            } label: {
                if isInstallingSecret {
                    ProgressView().controlSize(.small)
                } else {
                    Text(installedSecret == nil ? "Install DOCS_UPLOAD_TOKEN secret" : "Rotate token & reinstall")
                }
            }
            .disabled(isInstallingSecret)
        }
    }

    // MARK: - Documents

    @ViewBuilder
    private var documentsSection: some View {
        Section {
            if isLoading, documents.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            } else if documents.isEmpty {
                Text("No documents uploaded yet. Use the + button above to add one, or set up CI to upload them automatically.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(documents) { doc in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title ?? doc.docId).font(.body)
                            Text(doc.docId).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let status = doc.embeddingStatus {
                            Text(status)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(status == "ready" ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDocument = doc }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            documentToDelete = doc
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            documentToDelete = doc
                        } label: {
                            Label("Delete Document", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Documents (\(documents.count))")
        }
    }

    // MARK: - Danger zone

    @ViewBuilder
    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("Remove Documentation Repository")
            }
        }
    }

    // MARK: - Actions

    private func loadDocuments() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            documents = try await appState.docs.listDocuments(repoId: repo.id).items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSecret() async {
        isInstallingSecret = true
        installError = nil
        defer { isInstallingSecret = false }
        do {
            installedSecret = try await appState.docs.installGithubSecret(repoId: repo.id)
        } catch {
            installError = error.localizedDescription
        }
    }

    private func deleteDocument(_ doc: DocsDocument) async {
        documentToDelete = nil
        do {
            try await appState.docs.deleteDocument(repoId: repo.id, docId: doc.docId)
            documents.removeAll { $0.docId == doc.docId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRepo() async {
        do {
            try await appState.docs.deleteRepository(id: repo.id)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
