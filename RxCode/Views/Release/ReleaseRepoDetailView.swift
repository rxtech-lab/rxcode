import AppKit
import RxCodeCore
import SwiftUI

/// Detail for one release repository: lists its scanned workflows (highlighting
/// the selected dispatchable release workflow), lets the user install a
/// user-supplied `RELEASE_TOKEN` GitHub Actions secret, and create a release.
/// Mirrors `DocsRepoDetailView`.
struct ReleaseRepoDetailView: View {
    let repo: ReleaseRepo
    var onClose: () -> Void

    @Environment(AppState.self) private var appState

    @State private var workflows: [ReleaseWorkflow] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var releaseToken = ""
    @State private var isInstallingSecret = false
    @State private var installedSecret: ReleaseGithubSecretResult?
    @State private var installError: String?

    @State private var showDeleteConfirm = false
    @State private var showCreateRelease = false

    /// The workflow that "Create Release" dispatches: the selected dispatchable
    /// one, else any dispatchable one.
    private var defaultWorkflow: ReleaseWorkflow? {
        workflows.first(where: { $0.isSelected && $0.hasWorkflowDispatch })
            ?? workflows.first(where: { $0.hasWorkflowDispatch })
    }

    var body: some View {
        List {
            workflowsSection
            tokenSection
            createSection
            dangerSection
        }
        .navigationTitle(repo.repositoryFullName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onClose() }
            }
        }
        .task { await loadWorkflows() }
        .sheet(isPresented: $showCreateRelease) {
            ReleaseCreateSheet(
                repoId: repo.id,
                repoFullName: repo.repositoryFullName,
                currentVersion: repo.latestReleaseTag,
                branches: []
            )
            .environment(appState)
        }
        .alert("Remove this release repository?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) { Task { await deleteRepo() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unregisters \(repo.repositoryFullName) from the release service. The repo's files, workflows, and existing GitHub releases are not affected.")
        }
    }

    // MARK: - Workflows

    @ViewBuilder
    private var workflowsSection: some View {
        Section {
            if isLoading, workflows.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            } else if workflows.isEmpty {
                Text("No workflows scanned yet. Add a release workflow (e.g. .github/workflows/create-release.yaml) to the repo, then re-add the repository to rescan.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(workflows) { wf in
                    HStack(spacing: 10) {
                        Image(systemName: wf.hasWorkflowDispatch ? "play.circle" : "doc.plaintext")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wf.displayName).font(.body)
                            Text(wf.workflowPath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if wf.isSelected && wf.hasWorkflowDispatch {
                            Label("Release", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("Selected release workflow")
                        } else if wf.hasWorkflowDispatch {
                            Text("dispatchable")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Workflows (\(workflows.count))")
        }
    }

    // MARK: - RELEASE_TOKEN

    @ViewBuilder
    private var tokenSection: some View {
        Section("Release token") {
            Text("The release CI authenticates to GitHub with a RELEASE_TOKEN secret. Paste a GitHub token (a PAT with contents:write) and RxCode installs it as the repository's GitHub Actions secret for you — no terminal needed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("GitHub token (ghp_… / github_pat_…)", text: $releaseToken)
                .textFieldStyle(.roundedBorder)

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
                    Text(installedSecret == nil ? "Install RELEASE_TOKEN secret" : "Replace RELEASE_TOKEN secret")
                }
            }
            .disabled(isInstallingSecret || releaseToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Create release

    @ViewBuilder
    private var createSection: some View {
        Section {
            Button {
                showCreateRelease = true
            } label: {
                Label("Create Release…", systemImage: "tag.fill")
            }
            .disabled(defaultWorkflow == nil)
            if defaultWorkflow == nil {
                Text("Select a dispatchable release workflow first (re-add the repo to rescan if needed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Releases")
        } footer: {
            if let tag = repo.latestReleaseTag {
                Text("Latest release: \(tag)")
            }
        }
    }

    // MARK: - Danger zone

    @ViewBuilder
    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("Remove Release Repository")
            }
        }
    }

    // MARK: - Actions

    private func loadWorkflows() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            workflows = try await appState.release.listWorkflows(repoId: repo.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSecret() async {
        let value = releaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isInstallingSecret = true
        installError = nil
        defer { isInstallingSecret = false }
        do {
            installedSecret = try await appState.release.installReleaseToken(repoId: repo.id, value: value)
            releaseToken = ""
        } catch {
            installError = error.localizedDescription
        }
    }

    private func deleteRepo() async {
        do {
            try await appState.release.deleteRepository(id: repo.id)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
