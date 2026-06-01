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
    @Binding var showReleaseCreate: Bool
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
        // Docs search lives in the docs UI now — the context menu only offers
        // setting up / creating docs for the repo.
        Button {
            fire("Docs setup started on your Mac.") {
                try await state.requestProjectDocsSetup(projectId: project.id)
            }
        } label: {
            Label("Set Up Docs Search", systemImage: "books.vertical.fill")
        }
    }

    @ViewBuilder
    private func releaseItem(_ status: AutopilotProjectStatus) -> some View {
        if status.hasRelease {
            Button {
                // Show the create-release form on the phone (1:1 with the
                // on-device release dispatch form) instead of opening it on Mac.
                showReleaseCreate = true
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
        showReleaseCreate: Binding<Bool>,
        info: Binding<AutopilotMenuInfo?>,
        state: MobileAppState
    ) -> some View {
        modifier(ProjectAutopilotMenuHostModifier(
            project: project,
            status: status,
            showDownloadSheet: showDownloadSheet,
            showReleaseCreate: showReleaseCreate,
            info: info,
            state: state
        ))
    }
}

private struct ProjectAutopilotMenuHostModifier: ViewModifier {
    let project: Project?
    @Binding var status: AutopilotProjectStatus?
    @Binding var showDownloadSheet: Bool
    @Binding var showReleaseCreate: Bool
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
            .sheet(isPresented: $showReleaseCreate) {
                if let project {
                    ProjectReleaseCreateSheet(project: project)
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

// MARK: - Create-release form (on-device)

/// On-device "Create Release" form, mirroring the desktop `ReleaseCreateSheet`:
/// resolves the project's release workflows, lets the user pick a dispatchable
/// one, fills its `workflow_dispatch` inputs, and triggers it — all on the phone
/// (the desktop only relays the request). `repoId` is the `owner/repo` slug,
/// which the desktop resolves server-side just like the macOS sheet does.
struct ProjectReleaseCreateSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var workflows: [MobileReleaseWorkflow] = []
    @State private var selectedWorkflowId: String?
    @State private var branch = "main"
    @State private var inputValues: [String: String] = [:]
    @State private var isLoading = true
    @State private var isDispatching = false
    @State private var loadError: String?
    @State private var dispatchError: String?
    @State private var dispatchedURLString: String?

    private var repoFullName: String { project.gitHubRepo ?? "" }
    private var dispatchableWorkflows: [MobileReleaseWorkflow] {
        workflows.filter { $0.hasWorkflowDispatch }
    }
    private var selectedWorkflow: MobileReleaseWorkflow? {
        workflows.first { $0.id == selectedWorkflowId }
    }
    private var resolvedBranch: String {
        branch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else if dispatchableWorkflows.isEmpty {
                    Text("No dispatchable release workflow found for \(repoFullName). Add a workflow_dispatch release workflow and rescan, then try again.")
                        .foregroundStyle(.secondary)
                } else {
                    detailsSection
                    if let inputs = selectedWorkflow?.inputs, !inputs.isEmpty {
                        Section("Workflow inputs") {
                            ForEach(inputs) { inputField($0) }
                        }
                    }
                    if let dispatchError {
                        Section { Text(dispatchError).foregroundStyle(.red).font(.callout) }
                    }
                    if let dispatchedURLString, let url = URL(string: dispatchedURLString) {
                        Section {
                            Label("Release workflow triggered", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Link("View workflow run on GitHub", destination: url)
                        }
                    }
                }
            }
            .navigationTitle("Create Release")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(dispatchedURLString == nil ? "Cancel" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await dispatch() }
                    } label: {
                        if isDispatching { ProgressView() } else { Text("Create Release") }
                    }
                    .disabled(isDispatching || selectedWorkflow == nil || resolvedBranch.isEmpty || dispatchedURLString != nil)
                }
            }
            .mobileAutopilotLoadingOverlay(isLoading && workflows.isEmpty, title: "Loading workflows…")
        }
        .task { await load() }
    }

    private var detailsSection: some View {
        Section("Release") {
            LabeledContent("Repository", value: repoFullName)
            if dispatchableWorkflows.count > 1 {
                Picker("Workflow", selection: $selectedWorkflowId) {
                    ForEach(dispatchableWorkflows) { Text($0.displayName).tag(Optional($0.id)) }
                }
            } else if let wf = dispatchableWorkflows.first {
                LabeledContent("Workflow", value: wf.displayName)
            }
            TextField("Branch", text: $branch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("The next version is computed by semantic-release from the commit history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inputField(_ input: MobileReleaseWorkflowInput) -> some View {
        let label = input.name + (input.required ? " *" : "")
        if input.type == "boolean" {
            Toggle(label, isOn: Binding(
                get: { (inputValues[input.name] ?? (input.defaultBool == true ? "true" : "false")) == "true" },
                set: { inputValues[input.name] = $0 ? "true" : "false" }
            ))
        } else if input.type == "choice", let options = input.options {
            Picker(label, selection: Binding(
                get: { inputValues[input.name] ?? input.defaultString ?? options.first ?? "" },
                set: { inputValues[input.name] = $0 }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                TextField(label, text: Binding(
                    get: { inputValues[input.name] ?? input.defaultString ?? "" },
                    set: { inputValues[input.name] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if let desc = input.description, !desc.isEmpty {
                    Text(desc).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        guard !repoFullName.isEmpty else {
            loadError = String(localized: "This project is not linked to a GitHub repo.")
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            workflows = try await state.listReleaseWorkflows(repoId: repoFullName)
            let preferred = workflows.first { $0.isSelected && $0.hasWorkflowDispatch }
                ?? dispatchableWorkflows.first
            selectedWorkflowId = preferred?.id
            seedDefaults(for: preferred)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func seedDefaults(for workflow: MobileReleaseWorkflow?) {
        guard let inputs = workflow?.inputs else { return }
        for input in inputs where inputValues[input.name] == nil {
            if input.type == "boolean" {
                inputValues[input.name] = (input.defaultBool ?? false) ? "true" : "false"
            } else {
                inputValues[input.name] = input.defaultString ?? (input.options?.first ?? "")
            }
        }
    }

    private func dispatch() async {
        guard let workflow = selectedWorkflow else { return }
        isDispatching = true
        dispatchError = nil
        defer { isDispatching = false }
        do {
            let result = try await state.dispatchRelease(
                repoId: repoFullName,
                request: ReleaseDispatchRequest(
                    workflowId: workflow.id,
                    branch: resolvedBranch,
                    inputs: inputValues
                )
            )
            if let urlString = result.workflowRunUrl {
                dispatchedURLString = urlString
            } else if result.success == false {
                dispatchError = result.error ?? String(localized: "Failed to trigger the release workflow.")
            } else {
                dispatchedURLString = "https://github.com/\(repoFullName)/actions"
            }
        } catch {
            dispatchError = error.localizedDescription
        }
    }
}
