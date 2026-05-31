import RxCodeCore
import SwiftUI

/// Environments within a repo. Creating the first environment lazily registers
/// the repo for secrets management.
struct SecretsRepoDetailView: View {
    @Environment(AppState.self) private var appState

    let repo: SecretsManagedRepo
    var projectPath: String?

    @State private var repoId: String?
    @State private var environments: [SecretsEnvironment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showCreate = false
    @State private var newName = ""
    @State private var isMutating = false
    @State private var envToDelete: SecretsEnvironment?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(environments) { env in
                NavigationLink(value: SecretsEnvRoute(
                    repoIdentifier: repoId ?? repo.fullName,
                    repoFullName: repo.fullName,
                    env: env
                )) {
                    HStack {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(env.name)
                        Spacer()
                        if let count = env.filesCount {
                            Text("\(count)").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { envToDelete = env } label: {
                        Label("Delete Environment", systemImage: "trash")
                    }
                }
            }
            if environments.isEmpty, !isLoading {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No environments yet. Create one to store secrets.")
                        .foregroundStyle(.secondary)
                    Button { newName = ""; showCreate = true } label: {
                        Label("New Environment", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay { if isLoading, environments.isEmpty { ProgressView() } }
        .navigationTitle(repo.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newName = ""; showCreate = true } label: {
                    Label("New Environment", systemImage: "plus")
                }
            }
        }
        .alert("New Environment", isPresented: $showCreate) {
            TextField("Name (e.g. prod)", text: $newName)
            Button("Create") { Task { await createEnvironment() } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Letters, numbers, dot, dash and underscore. Max 32 characters.")
        }
        .confirmationDialog(
            "Delete \"\(envToDelete?.name ?? "")\"?",
            isPresented: Binding(get: { envToDelete != nil }, set: { if !$0 { envToDelete = nil } }),
            titleVisibility: .visible
        ) {
            // Capture synchronously: dialog dismissal clears `envToDelete`
            // before the async Task body runs.
            Button("Delete", role: .destructive) {
                let env = envToDelete
                Task { await deleteEnvironment(env) }
            }
            Button("Cancel", role: .cancel) { envToDelete = nil }
        } message: {
            Text("All secrets in this environment will be permanently deleted.")
        }
        .task { await load() }
    }

    private func load() async {
        guard let id = repoId ?? repo.secretsRepoId else {
            // Unmanaged repo — nothing stored yet.
            environments = []
            return
        }
        repoId = id
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            environments = try await appState.secrets.listEnvironments(repo: id).items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createEnvironment() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            let id = try await appState.ensureSecretsRepoManaged(repo)
            repoId = id
            try await appState.createSecretEnvironment(repo: id, name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEnvironment(_ env: SecretsEnvironment?) async {
        guard let env, let id = repoId else { return }
        envToDelete = nil
        do {
            try await appState.secrets.deleteEnvironment(repo: id, envId: env.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
