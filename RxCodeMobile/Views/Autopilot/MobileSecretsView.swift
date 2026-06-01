import RxCodeCore
import RxCodeSync
import SwiftUI

/// Secrets management: repositories → environments → encrypted files. The
/// desktop holds the passkey-derived key and performs all encryption and
/// decryption; plaintext only ever travels over the already-E2E sync channel.
/// Enrollment itself stays a Mac-side passkey action.
struct MobileSecretsView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var enrolled: Bool?
    @State private var repos: [SecretsManagedRepo] = []
    @State private var search = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            switch enrolled {
            case .some(false):
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Encryption not set up")
                            Text("Enroll with your passkey on your Mac to manage secrets.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.slash").foregroundStyle(.orange)
                    }
                }
            case .some(true):
                ForEach(repos) { repo in
                    NavigationLink {
                        MobileSecretsRepoView(repoFullName: repo.fullName)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: repo.isManaged ? "key.fill" : "key")
                                .foregroundStyle(repo.isManaged ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName)
                                if repo.isManaged {
                                    Text("\(repo.environmentsCount) environment(s), \(repo.filesCount) file(s)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if repos.isEmpty, !isLoading {
                    Text("No repositories available.").foregroundStyle(.secondary)
                }
            case .none:
                if isLoading {
                    HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Secrets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .onChange(of: search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await reloadRepos()
            }
        }
        .mobileAutopilotLoadingOverlay(enrolled == nil && isLoading)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            enrolled = try await state.secretsEnrollmentStatus()
            if enrolled == true { await reloadRepos() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadRepos() async {
        do {
            repos = try await state.listAutopilotRepos(search: search).items
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Environments for one secrets repo.
struct MobileSecretsRepoView: View {
    @EnvironmentObject private var state: MobileAppState
    let repoFullName: String

    @State private var environments: [SecretsEnvironment] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var pendingDelete: SecretsEnvironment?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(environments) { env in
                NavigationLink {
                    MobileSecretsEnvironmentView(repoFullName: repoFullName, environment: env)
                } label: {
                    HStack {
                        Label(env.name, systemImage: "leaf")
                        Spacer()
                        if let count = env.filesCount {
                            Text("\(count)").foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = env }
                }
            }
            if environments.isEmpty, !isLoading {
                Text("No environments yet. Tap + to add one.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(repoFullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("New environment", isPresented: $showingAdd) {
            TextField("Name (e.g. production)", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        }
        .alert(
            "Delete environment?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let env = pendingDelete { Task { await delete(env) } }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently deletes the environment and its secret files.")
        }
        .mobileAutopilotLoadingOverlay(isLoading && environments.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            environments = try await state.listSecretEnvironments(repo: repoFullName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await state.createSecretEnvironment(repo: repoFullName, name: name)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ env: SecretsEnvironment) async {
        do {
            try await state.deleteSecretEnvironment(repo: repoFullName, envId: env.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Files in one environment, with on-demand decrypted values.
struct MobileSecretsEnvironmentView: View {
    @EnvironmentObject private var state: MobileAppState
    let repoFullName: String
    let environment: SecretsEnvironment

    @State private var files: [SecretsFileMeta] = []
    @State private var plaintextByName: [String: String] = [:]
    @State private var revealed = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editingFile: EditingFile?
    @State private var pendingDelete: SecretsFileMeta?

    struct EditingFile: Identifiable {
        let id = UUID()
        var filename: String
        var content: String
        let isNew: Bool
    }

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section {
                Button {
                    Task { await toggleReveal() }
                } label: {
                    Label(revealed ? "Hide values" : "View values",
                          systemImage: revealed ? "eye.slash" : "eye")
                }
            }
            Section("Files") {
                ForEach(files) { file in
                    Button {
                        Task { await edit(file) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.filename).foregroundStyle(.primary)
                            if revealed, let value = plaintextByName[file.filename] {
                                Text(value)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = file }
                    }
                }
                if files.isEmpty, !isLoading {
                    Text("No files yet. Tap + to add one.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(environment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingFile = EditingFile(filename: "", content: "", isNew: true)
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editingFile) { item in
            MobileSecretFileEditor(repoFullName: repoFullName, envId: environment.id, file: item) {
                await reload()
                if revealed { await loadPlaintext() }
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .alert(
            "Delete file?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { Task { await delete(file) } }
                pendingDelete = nil
            }
        }
        .mobileAutopilotLoadingOverlay(isLoading && files.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            files = try await state.listSecretFiles(repo: repoFullName, envId: environment.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleReveal() async {
        if revealed {
            revealed = false
            return
        }
        await loadPlaintext()
        revealed = true
    }

    private func loadPlaintext() async {
        do {
            let files = try await state.secretEnvironmentPlaintext(repo: repoFullName, envId: environment.id)
            plaintextByName = Dictionary(files.map { ($0.filename, $0.content) }, uniquingKeysWith: { _, last in last })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func edit(_ file: SecretsFileMeta) async {
        // Ensure we have the plaintext for this file before opening the editor.
        if plaintextByName[file.filename] == nil {
            await loadPlaintext()
        }
        editingFile = EditingFile(
            filename: file.filename,
            content: plaintextByName[file.filename] ?? "",
            isNew: false
        )
    }

    private func delete(_ file: SecretsFileMeta) async {
        do {
            try await state.deleteSecretFile(repo: repoFullName, envId: environment.id, fileId: file.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Create or edit a single secret file. The desktop re-encrypts on save.
struct MobileSecretFileEditor: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repoFullName: String
    let envId: String
    let file: MobileSecretsEnvironmentView.EditingFile
    let onSaved: () async -> Void

    @State private var filename: String
    @State private var content: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        repoFullName: String,
        envId: String,
        file: MobileSecretsEnvironmentView.EditingFile,
        onSaved: @escaping () async -> Void
    ) {
        self.repoFullName = repoFullName
        self.envId = envId
        self.file = file
        self.onSaved = onSaved
        _filename = State(initialValue: file.filename)
        _content = State(initialValue: file.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filename") {
                    TextField(".env", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!file.isNew)
                }
                Section("Contents") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle(file.isNew ? "Add File" : filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || filename.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await state.upsertSecretFile(
                repo: repoFullName,
                envId: envId,
                filename: filename.trimmingCharacters(in: .whitespacesAndNewlines),
                content: content
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
