import RxCodeCore
import SwiftUI

/// Per-project "Download Secret" flow: pick an environment for the project's
/// repository, then decrypt (passkey) and write the files into the project.
struct SecretsDownloadSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var environments: [SecretsEnvironment] = []
    @State private var selectedEnvId: String?
    @State private var overwrite = true
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var written: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Secret").font(.headline)

            if let repo = project.gitHubRepo {
                Text(repo).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                bodyContent(repo: repo)
            } else {
                Text("This project isn't linked to a GitHub repository, so it has no secrets to download.")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            if let written {
                if written.isEmpty {
                    Label("Nothing written (files already exist).", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("Wrote \(written.joined(separator: ", ")) to the project.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.green)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(written == nil ? "Cancel" : "Done") { dismiss() }
                if project.gitHubRepo != nil, written == nil {
                    Button {
                        Task { await download() }
                    } label: {
                        if isDownloading { ProgressView().controlSize(.small) } else { Text("Download") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || selectedEnvId == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
        .task { await load() }
    }

    @ViewBuilder
    private func bodyContent(repo: String) -> some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if environments.isEmpty {
            Text("No environments found for this repository. Add secrets from Settings → Secrets first.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Environment", selection: $selectedEnvId) {
                ForEach(environments) { env in
                    Text(env.name).tag(Optional(env.id))
                }
            }
            Toggle("Overwrite existing files", isOn: $overwrite)
            Text("Decrypts with your passkey and writes the .env file(s) into the project folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let repo = project.gitHubRepo else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            environments = try await appState.secrets.listEnvironments(repo: repo).items
            selectedEnvId = environments.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download() async {
        guard let repo = project.gitHubRepo, let envId = selectedEnvId else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            let files = try await appState.downloadSecrets(
                repo: repo,
                env: envId,
                to: URL(fileURLWithPath: project.path, isDirectory: true),
                overwrite: overwrite
            )
            written = files
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
