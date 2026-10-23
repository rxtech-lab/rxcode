import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Release management: registered release repositories, their scanned
/// workflows, recent releases, the RELEASE_TOKEN secret, and creating releases.
struct MobileReleaseView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var repos: [ReleaseRepo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var pendingDelete: ReleaseRepo?
    @State private var isRemoving = false

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(repos) { repo in
                NavigationLink {
                    MobileReleaseRepoDetailView(repo: repo, onRemoved: { await reload() })
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.repositoryFullName).lineLimit(1).truncationMode(.middle)
                        Text(repo.latestReleaseTag.map { "Latest: \($0)" } ?? String(localized: "No releases yet"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { pendingDelete = repo }
                }
                .contextMenu {
                    Button("Remove Repository", systemImage: "trash", role: .destructive) { pendingDelete = repo }
                }
            }
        }
        .overlay {
            if repos.isEmpty, !isLoading, errorMessage == nil {
                ContentUnavailableView {
                    Label("No Release Repositories", systemImage: "shippingbox")
                } description: {
                    Text("Add a repository to create releases from its GitHub Actions workflows.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Repository", systemImage: "plus") {
                    MobileHaptics.buttonTap()
                    showingAdd = true
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            MobileAutopilotRepoPicker(
                title: "Add Release Repository",
                existingRepoFullNames: Set(repos.map { $0.repositoryFullName.lowercased() })
            ) { repo in
                await add(repo)
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .confirmationDialog(
            "Remove \(pendingDelete?.repositoryFullName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Repository", role: .destructive) {
                if let repo = pendingDelete { Task { await delete(repo) } }
                pendingDelete = nil
            }
        } message: {
            Text("Flowcy stops managing releases for this repository. Existing GitHub releases are not affected.")
        }
        .mobileAutopilotLoadingDialog(isRemoving, title: "Removing repository…")
        .mobileAutopilotLoadingOverlay(isLoading && repos.isEmpty)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repos = try await state.listReleaseRepos().items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ repo: SecretsManagedRepo) async {
        do {
            try await state.addReleaseRepo(AddReleaseRepoBody(
                installationId: repo.installationId,
                repositoryId: repo.id,
                repositoryFullName: repo.fullName
            ))
            MobileHaptics.connected()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }

    private func delete(_ repo: ReleaseRepo) async {
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await state.deleteReleaseRepo(id: repo.id)
            MobileHaptics.connected()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}

// MARK: - Repository detail

/// Workflows and recent releases. "Release" in the toolbar starts the
/// pick-a-workflow → fill-inputs flow; everything else lives in the menu.
struct MobileReleaseRepoDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let repo: ReleaseRepo
    var onRemoved: (() async -> Void)? = nil

    @State private var workflows: [MobileReleaseWorkflow] = []
    @State private var history: [ReleaseDispatchHistoryItem]?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var busyTitle: LocalizedStringKey?
    @State private var releasing: ReleaseStart?
    @State private var showingToken = false
    @State private var confirmRemove = false

    /// Starting point of the release sheet: the workflow list, or one workflow.
    struct ReleaseStart: Identifiable {
        let workflow: MobileReleaseWorkflow?
        var id: String { workflow?.id ?? "picker" }
    }

    private var sortedWorkflows: [MobileReleaseWorkflow] { MobileReleaseWorkflow.releaseOrder(workflows) }
    private var dispatchable: [MobileReleaseWorkflow] { sortedWorkflows.filter(\.hasWorkflowDispatch) }

    var body: some View {
        List {
            Section {
                LabeledContent("Latest Release", value: repo.latestReleaseTag ?? String(localized: "None"))
                LabeledContent("Release Workflows", value: "\(workflows.filter(\.isSelected).count)")
            } header: {
                Text(repo.repositoryFullName)
            }

            Section {
                ForEach(sortedWorkflows) { workflow in
                    NavigationLink {
                        MobileWorkflowFileView(repoId: repo.id, workflow: workflow,
                                               onRelease: workflow.hasWorkflowDispatch ? { startRelease(workflow) } : nil,
                                               onToggleRelease: { await toggleRelease(workflow) })
                    } label: {
                        MobileReleaseWorkflowRow(workflow: workflow)
                    }
                    .contextMenu { workflowMenu(workflow) }
                    .swipeActions(edge: .leading) {
                        if workflow.hasWorkflowDispatch {
                            Button("Release", systemImage: "paperplane") { startRelease(workflow) }.tint(.accentColor)
                        }
                    }
                }
            } header: {
                Text("Workflows")
            } footer: {
                if workflows.isEmpty, !isLoading {
                    Text("No workflows found. Choose Rescan Workflows from the menu after adding files to .github/workflows.")
                } else {
                    Text("Tap a workflow to view its file. Long-press for more options.")
                }
            }

            if let history {
                Section("Recent Releases") {
                    if history.isEmpty {
                        Text("No releases created from Flowcy yet.").foregroundStyle(.secondary)
                    }
                    ForEach(history.prefix(5)) { item in
                        NavigationLink {
                            MobileReleaseDispatchDetailView(item: item, workflowName: workflowName(item.releaseWorkflowId))
                        } label: {
                            MobileReleaseDispatchRow(item: item, workflowName: workflowName(item.releaseWorkflowId))
                        }
                    }
                    if history.count > 5 {
                        NavigationLink("Show All") {
                            List(history) { item in
                                NavigationLink {
                                    MobileReleaseDispatchDetailView(item: item, workflowName: workflowName(item.releaseWorkflowId))
                                } label: {
                                    MobileReleaseDispatchRow(item: item, workflowName: workflowName(item.releaseWorkflowId))
                                }
                            }
                            .navigationTitle("Recent Releases")
                        }
                    }
                }
            }
        }
        .navigationTitle(repo.repositoryFullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Release", systemImage: "paperplane") { startRelease(nil) }
                    .disabled(busyTitle != nil || (!isLoading && dispatchable.isEmpty))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rescan Workflows", systemImage: "arrow.clockwise") { Task { await rescan() } }
                    Button("Install RELEASE_TOKEN", systemImage: "key.horizontal") {
                        MobileHaptics.buttonTap()
                        showingToken = true
                    }
                    Section {
                        Button("Remove Repository", systemImage: "trash", role: .destructive) {
                            MobileHaptics.buttonTap()
                            confirmRemove = true
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(busyTitle != nil)
            }
        }
        .sheet(item: $releasing) { start in
            NavigationStack {
                if let workflow = start.workflow {
                    MobileReleaseDispatchView(repo: repo, workflow: workflow, isRoot: true) { message in
                        await didRelease(message)
                    }
                } else {
                    MobileReleaseWorkflowPicker(repo: repo, workflows: dispatchable) { message in
                        await didRelease(message)
                    }
                }
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .sheet(isPresented: $showingToken) {
            MobileReleaseTokenSheet(repo: repo) { name in
                toast = String(localized: "Installed \(name).")
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .confirmationDialog("Remove \(repo.repositoryFullName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Repository", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Flowcy stops managing releases for this repository. Existing GitHub releases are not affected.")
        }
        .alert("Could Not Complete Request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .mobileAutopilotLoadingDialog(busyTitle != nil, title: busyTitle ?? "Working…")
        .mobileAutopilotLoadingOverlay(isLoading && workflows.isEmpty)
        .mobileStatusToast($toast)
        .refreshable { await reload() }
        .task { await reload() }
    }

    @ViewBuilder private func workflowMenu(_ workflow: MobileReleaseWorkflow) -> some View {
        if workflow.hasWorkflowDispatch {
            Button("Release with This Workflow", systemImage: "paperplane") { startRelease(workflow) }
        }
        Button(workflow.isSelected ? "Unmark as Release Workflow" : "Mark as Release Workflow",
               systemImage: workflow.isSelected ? "tag.slash" : "tag") {
            Task { await toggleRelease(workflow) }
        }
    }

    private func workflowName(_ id: String?) -> String? {
        workflows.first { $0.id == id }?.displayName
    }

    private func startRelease(_ workflow: MobileReleaseWorkflow?) {
        MobileHaptics.buttonTap()
        guard workflow != nil || !dispatchable.isEmpty else {
            errorMessage = String(localized: "No workflow in this repository can be started manually. Add a workflow_dispatch trigger, then rescan workflows.")
            return
        }
        releasing = ReleaseStart(workflow: workflow)
    }

    private func didRelease(_ message: String) async {
        releasing = nil
        toast = message
        MobileHaptics.connected()
        history = try? await state.releaseDispatchHistory(repoId: repo.id)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            workflows = try await state.listReleaseWorkflows(repoId: repo.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Older servers don't expose history to the app; hide the section then.
        history = try? await state.releaseDispatchHistory(repoId: repo.id)
    }

    private func rescan() async {
        MobileHaptics.buttonTap()
        busyTitle = "Rescanning workflows…"
        defer { busyTitle = nil }
        do {
            let result = try await state.rescanReleaseWorkflows(repoId: repo.id)
            workflows = try await state.listReleaseWorkflows(repoId: repo.id)
            MobileHaptics.connected()
            toast = String(localized: "Found \(result.workflowsFound) workflows (\(result.releaseWorkflowsFound) release).")
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }

    private func toggleRelease(_ workflow: MobileReleaseWorkflow) async {
        MobileHaptics.buttonTap()
        busyTitle = "Updating workflow…"
        defer { busyTitle = nil }
        do {
            try await state.setReleaseWorkflowSelected(repoId: repo.id, workflowId: workflow.id, isSelected: !workflow.isSelected)
            workflows = try await state.listReleaseWorkflows(repoId: repo.id)
            MobileHaptics.connected()
            toast = workflow.isSelected
                ? String(localized: "\(workflow.displayName) is no longer a release workflow.")
                : String(localized: "\(workflow.displayName) marked as a release workflow.")
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        busyTitle = "Removing repository…"
        defer { busyTitle = nil }
        do {
            try await state.deleteReleaseRepo(id: repo.id)
            MobileHaptics.connected()
            if let onRemoved { await onRemoved() }
            dismiss()
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }
}

extension MobileReleaseWorkflow {
    /// Release workflows first, then manually triggerable ones, then by name.
    static func releaseOrder(_ workflows: [MobileReleaseWorkflow]) -> [MobileReleaseWorkflow] {
        workflows.sorted {
            if $0.isSelected != $1.isSelected { return $0.isSelected }
            if $0.hasWorkflowDispatch != $1.hasWorkflowDispatch { return $0.hasWorkflowDispatch }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

struct MobileReleaseWorkflowRow: View {
    let workflow: MobileReleaseWorkflow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: workflow.isSelected ? "tag.fill" : "doc.text")
                .foregroundStyle(workflow.isSelected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(workflow.displayName).font(.headline).lineLimit(2)
                Text(workflow.workflowPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if workflow.isSelected { MobileReleaseBadge(title: "Release", color: .accentColor) }
                    if workflow.hasWorkflowDispatch { MobileReleaseBadge(title: "Manual Trigger", color: .green) }
                    if let count = workflow.inputs?.count, count > 0 {
                        MobileReleaseBadge(title: "\(count) inputs", color: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MobileReleaseBadge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
