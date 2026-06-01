import SwiftUI
import RxCodeCore
import RxCodeSync

/// One-to-one mobile mirror of the desktop project/briefing autopilot context
/// menu (`AutopilotSecretsHook` / `AutopilotDocsHook` / `AutopilotReleaseHook`).
///
/// The desktop shows, per project (gated on a linked GitHub repo):
///   • Download Secret  / Set Up Secrets          (key.fill)
///   • Search Docs      / Set Up Docs Search       (books.vertical.fill)
///   • Create Release   / Set Up Release Workflow  (tag.fill)
///
/// Every item is desktop-mediated — the Mac performs the same work it does when
/// you click the menu there. The one exception that runs UI on the phone is
/// "Download Secret", which opens the on-device environment picker before asking
/// the Mac to decrypt + write the files into the project folder.
///
/// Drop the buttons into any `Menu { }` or `.contextMenu { }`; the host owns the
/// `@State` for the loaded status, the download sheet, and the info alert and
/// passes them in. Use `projectAutopilotMenu(...)` on a host that already has a
/// stable identity (toolbar button, project card) so the sheet/alert can attach.

/// A transient message surfaced after a desktop-mediated action fires (e.g.
/// "Secrets setup started on your Mac") or when one fails.
struct AutopilotMenuInfo: Identifiable {
    let id = UUID()
    let text: String
    var isError = false
}

struct ProjectAutopilotMenuItems: View {
    @EnvironmentObject private var state: MobileAppState
    let project: Project
    /// Loaded per-project state; `nil` while the first fetch is in flight.
    let status: AutopilotProjectStatus?
    @Binding var showDownloadSheet: Bool
    @Binding var info: AutopilotMenuInfo?

    var body: some View {
        // Mirror the desktop guard: no repo → no autopilot items.
        if project.gitHubRepo == nil {
            EmptyView()
        } else if let status {
            secretsItem(status)
            docsItem(status)
            releaseItem(status)
        } else {
            Button {} label: {
                Label("Loading Autopilot…", systemImage: "hourglass")
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private func secretsItem(_ status: AutopilotProjectStatus) -> some View {
        if status.hasSecrets {
            Button {
                showDownloadSheet = true
            } label: {
                Label("Download Secret", systemImage: "key.fill")
            }
        } else {
            Button {
                fire("Secrets setup started on your Mac.") {
                    try await state.requestProjectSecretsSetup(projectId: project.id)
                }
            } label: {
                Label("Set Up Secrets", systemImage: "key.fill")
            }
        }
    }

    @ViewBuilder
    private func docsItem(_ status: AutopilotProjectStatus) -> some View {
        if status.hasDocs {
            Button {
                fire("Opened docs search on your Mac.") {
                    try await state.requestProjectDocsSearch(projectId: project.id)
                }
            } label: {
                Label("Search Docs", systemImage: "books.vertical.fill")
            }
        } else {
            Button {
                fire("Docs setup started on your Mac.") {
                    try await state.requestProjectDocsSetup(projectId: project.id)
                }
            } label: {
                Label("Set Up Docs Search", systemImage: "books.vertical.fill")
            }
        }
    }

    @ViewBuilder
    private func releaseItem(_ status: AutopilotProjectStatus) -> some View {
        if status.hasRelease {
            Button {
                fire("Opened create-release on your Mac.") {
                    try await state.requestProjectReleaseCreate(projectId: project.id)
                }
            } label: {
                Label("Create Release", systemImage: "tag.fill")
            }
        } else {
            Button {
                fire("Release setup started on your Mac.") {
                    try await state.requestProjectReleaseSetup(projectId: project.id)
                }
            } label: {
                Label("Set Up Release Workflow", systemImage: "tag.fill")
            }
        }
    }

    /// Runs a desktop-mediated action and reports success/failure via the alert.
    private func fire(_ success: String, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                info = AutopilotMenuInfo(text: success)
            } catch {
                info = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }
}

// MARK: - Host modifier

extension View {
    /// Attaches the per-project autopilot status loader, the secrets-download
    /// sheet, and the action-result alert to a host view. Pair with
    /// `ProjectAutopilotMenuItems` placed inside the host's `Menu`/`.contextMenu`.
    func projectAutopilotMenuHost(
        project: Project?,
        status: Binding<AutopilotProjectStatus?>,
        showDownloadSheet: Binding<Bool>,
        info: Binding<AutopilotMenuInfo?>,
        state: MobileAppState
    ) -> some View {
        modifier(ProjectAutopilotMenuHostModifier(
            project: project,
            status: status,
            showDownloadSheet: showDownloadSheet,
            info: info,
            state: state
        ))
    }
}

private struct ProjectAutopilotMenuHostModifier: ViewModifier {
    let project: Project?
    @Binding var status: AutopilotProjectStatus?
    @Binding var showDownloadSheet: Bool
    @Binding var info: AutopilotMenuInfo?
    let state: MobileAppState

    func body(content: Content) -> some View {
        content
            .task(id: project?.id) {
                // Only repo-backed projects have autopilot state to load.
                guard let project, project.gitHubRepo != nil else { return }
                status = try? await state.projectAutopilotStatus(projectId: project.id)
            }
            .sheet(isPresented: $showDownloadSheet) {
                if let project {
                    ProjectSecretsDownloadSheet(project: project)
                        .environmentObject(state)
                        .mobileSheetPresentation()
                }
            }
            .alert(item: $info) { message in
                Alert(
                    title: Text(message.isError ? "Couldn’t Complete" : "Sent to Your Mac"),
                    message: Text(message.text),
                    dismissButton: .default(Text("OK"))
                )
            }
    }
}

// MARK: - Secrets download form

/// Mobile mirror of the desktop secrets auto-download (`AutopilotSecretsHook`):
/// pick an environment, then ask the Mac to decrypt it and write the files into
/// the project folder. The phone never sees plaintext — the Mac holds the KEK.
struct ProjectSecretsDownloadSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let project: Project
    /// When true (first-add flow), dismiss instead of showing the "No Secrets"
    /// empty state — the form should only linger when there's something to grab.
    var autoDismissWhenEmpty = false

    @State private var environments: [SecretsEnvironment] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedEnvId: String?
    @State private var overwrite = false
    @State private var isDownloading = false
    @State private var actionError: String?
    /// Files skipped on the last attempt because they already exist — surfaced
    /// as a prompt to enable overwrite (mirrors the desktop overwrite confirm).
    @State private var conflicts: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn’t Load Environments",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if !isLoading && environments.isEmpty {
                    ContentUnavailableView(
                        "No Secrets",
                        systemImage: "key",
                        description: Text("This repository has no secret environments to download.")
                    )
                } else {
                    form
                }
            }
            .navigationTitle("Download Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        download()
                    } label: {
                        if isDownloading { ProgressView() } else { Text("Download") }
                    }
                    .disabled(selectedEnvId == nil || isDownloading)
                }
            }
            .mobileAutopilotLoadingOverlay(isLoading && environments.isEmpty, title: "Loading environments…")
        }
        .task { await loadEnvironments() }
    }

    private var form: some View {
        List {
            Section {
                ForEach(environments) { env in
                    Button {
                        selectedEnvId = env.id
                    } label: {
                        HStack {
                            Text(env.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedEnvId == env.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Files are decrypted on your Mac and written into the project folder.")
            }

            Section {
                Toggle("Overwrite existing files", isOn: $overwrite)
            } footer: {
                if !conflicts.isEmpty {
                    Text("These files already exist and were skipped: \(conflicts.joined(separator: ", ")). Turn on overwrite to replace them.")
                        .foregroundStyle(.orange)
                }
            }

            if let actionError {
                Section {
                    Text(actionError)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func loadEnvironments() async {
        guard let repo = project.gitHubRepo else {
            loadError = String(localized: "This project is not linked to a GitHub repo.")
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let envs = try await state.listSecretEnvironments(repo: repo)
            environments = envs
            // First-add: nothing to download → close instead of an empty sheet.
            if envs.isEmpty, autoDismissWhenEmpty {
                dismiss()
                return
            }
            // Preselect when there's only one, matching a single-choice download.
            if envs.count == 1 { selectedEnvId = envs.first?.id }
        } catch {
            if autoDismissWhenEmpty {
                // First-add is best-effort — don't block project creation on a
                // secrets check that failed (offline, not enrolled, etc.).
                dismiss()
                return
            }
            loadError = error.localizedDescription
        }
    }

    private func download() {
        guard let envId = selectedEnvId else { return }
        isDownloading = true
        actionError = nil
        conflicts = []
        Task {
            defer { isDownloading = false }
            do {
                let result = try await state.downloadProjectSecrets(
                    projectId: project.id,
                    envId: envId,
                    overwrite: overwrite
                )
                if !result.conflicts.isEmpty {
                    // Some files were skipped — keep the sheet open and prompt to
                    // overwrite, exactly like the desktop confirm step.
                    conflicts = result.conflicts
                } else {
                    dismiss()
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
