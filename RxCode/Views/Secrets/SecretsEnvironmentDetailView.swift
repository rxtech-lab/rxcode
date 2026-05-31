import RxCodeCore
import SwiftUI

/// Files within an environment. Loads the encrypted bundle (env key + file
/// ciphertexts) up front; decryption is deferred until the user views a file.
struct SecretsEnvironmentDetailView: View {
    @Environment(AppState.self) private var appState

    let route: SecretsEnvRoute
    var projectPath: String?
    /// Closes the enclosing Manage Secrets sheet (threaded from
    /// `SecretsManageSheet`), so "Done" stays reachable from this pushed view.
    var onClose: (() -> Void)?

    @State private var environmentKey: SecretsEnvironmentKey?
    @State private var files: [SecretsBundleFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showAdd = false
    @State private var editingFile: SecretsBundleFile?
    @State private var fileToDelete: SecretsBundleFile?
    @State private var deletingFilename: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(files) { file in
                Button { editingFile = file } label: {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file.filename)
                        Spacer()
                        if let size = file.size {
                            Text("\(size) B").foregroundStyle(.secondary).font(.caption)
                        }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { fileToDelete = file } label: {
                        Label("Delete Secret", systemImage: "trash")
                    }
                }
            }
            if files.isEmpty, !isLoading {
                Text("No secrets yet. Add a .env file or enter values manually.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay { if isLoading, files.isEmpty { ProgressView() } }
        .overlay {
            if let deletingFilename {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Deleting \"\(deletingFilename)\"…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: deletingFilename)
        .navigationTitle(route.env.name)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add Secret", systemImage: "plus") }
                    .disabled(environmentKey == nil)
            }
        }
        .sheet(isPresented: $showAdd) {
            if let environmentKey {
                AddSecretSheet(
                    repoIdentifier: route.repoIdentifier,
                    envId: route.env.id,
                    environmentKey: environmentKey,
                    projectPath: projectPath,
                    existingFilenames: Set(files.map(\.filename))
                ) {
                    Task { await load() }
                }
            }
        }
        .sheet(item: $editingFile) { file in
            if let environmentKey {
                SecretsFileEditor(
                    repoIdentifier: route.repoIdentifier,
                    envId: route.env.id,
                    environmentKey: environmentKey,
                    file: file
                ) {
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(fileToDelete?.filename ?? "")\"?",
            isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }),
            titleVisibility: .visible
        ) {
            // Capture the target synchronously: dismissing the dialog clears
            // `fileToDelete` before the async Task body runs, so reading it
            // inside `deleteFile()` would see nil and silently no-op.
            Button("Delete", role: .destructive) {
                let file = fileToDelete
                Task { await deleteFile(file) }
            }
            Button("Cancel", role: .cancel) { fileToDelete = nil }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let bundle = try await appState.secrets.bundle(repo: route.repoIdentifier, env: route.env.id)
            environmentKey = bundle.environmentKey
            files = bundle.files
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteFile(_ file: SecretsBundleFile?) async {
        guard let file else { return }
        fileToDelete = nil
        deletingFilename = file.filename
        defer { deletingFilename = nil }
        // Look up the file id via the metadata listing (bundle has no id).
        do {
            let metas = try await appState.secrets.listFiles(repo: route.repoIdentifier, envId: route.env.id).items
            guard let meta = metas.first(where: { $0.filename == file.filename }) else { return }
            try await appState.secrets.deleteFile(repo: route.repoIdentifier, envId: route.env.id, fileId: meta.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - File editor

/// View / edit one secret file's plaintext. Decrypts on appear (passkey), saves
/// by re-encrypting under the environment DEK.
struct SecretsFileEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let repoIdentifier: String
    let envId: String
    let environmentKey: SecretsEnvironmentKey
    let file: SecretsBundleFile
    var onSaved: () -> Void

    @State private var content = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.filename).font(.headline)
            if isLoading {
                ProgressView("Decrypting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .border(Color(NSColor.separatorColor))
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isSaving)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .task { await decrypt() }
    }

    private func decrypt() async {
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await appState.decryptSecretFile(
                envKey: environmentKey, ciphertext: file.ciphertext, iv: file.iv
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let body = try await appState.encryptSecretFile(
                forEnvironmentKey: environmentKey, filename: file.filename, content: content
            )
            _ = try await appState.secrets.upsertFile(repo: repoIdentifier, envId: envId, body: body)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
