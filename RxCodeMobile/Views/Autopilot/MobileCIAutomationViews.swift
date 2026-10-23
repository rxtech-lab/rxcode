import Combine
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Automation summary

/// Read-only view of the saved automation; editing happens in its own sheet.
struct MobileAutomationSummaryView: View {
    @EnvironmentObject private var state: MobileAppState
    @ObservedObject var model: MobileCIRepoModel
    let onEdit: () -> Void

    var body: some View {
        Group {
            if let automation = model.automation {
                List {
                    Section("Updates") {
                        LabeledContent("Scan Frequency", value: model.repo.scanFrequency.displayName)
                        status("Dependency updates", automation.settings.dependenciesEnabled)
                        status("AI repair of failing dependency CI", automation.settings.dependencyCiRepair)
                        status("Auto-merge dependency PRs", automation.settings.dependencyAutoMerge)
                        status("Auto-merge CI update PRs", automation.settings.ciAutoMerge)
                    }
                    Section("Projects") {
                        ForEach(automation.settings.targets, id: \.directory) { target in
                            LabeledContent(target.displayDirectory, value: target.manager.displayName)
                                .font(.body.monospaced())
                        }
                    }
                    Section("Security") {
                        status("Dependency vulnerability scans", automation.settings.dependencySecurityEnabled)
                        status("Dependency vulnerability emails", automation.settings.dependencyNotifications)
                        status("GitHub Actions vulnerability scans", automation.settings.ciSecurityEnabled)
                        status("GitHub Actions vulnerability emails", automation.settings.ciNotifications)
                    }
                }
            } else {
                ContentUnavailableView("Automation Unavailable", systemImage: "wand.and.stars",
                                       description: Text(model.automationError ?? String(localized: "Pull to refresh the repository.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Automation")
        .refreshable { await model.reloadAutomation(state) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { MobileHaptics.buttonTap(); onEdit() }.disabled(model.automation == nil)
            }
        }
    }

    private func status(_ title: LocalizedStringKey, _ on: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(on ? .green : .secondary)
                .accessibilityLabel(on ? "On" : "Off")
        }
    }
}

// MARK: - Automation settings editor

struct MobileAutomationSettingsSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileCIRepoModel
    let onSaved: (String) -> Void

    @State private var draft = RepositoryAutomationSettings()
    @State private var frequency: CIScanFrequency = .weekly
    @State private var original: (RepositoryAutomationSettings, CIScanFrequency)?
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var errorMessage: String?

    private var isDirty: Bool {
        guard let original else { return false }
        return original.0 != draft || original.1 != frequency
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scan Frequency", selection: $frequency) {
                        ForEach(CIScanFrequency.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if model.repo.scheduleId == nil {
                        Text("No automatic schedule is active. Saving creates one with this frequency.")
                    }
                }

                Section {
                    Toggle("Automatically update dependencies", isOn: $draft.dependenciesEnabled)
                    Toggle("Use AI to remove incompatible updates when dependency CI fails", isOn: $draft.dependencyCiRepair)
                    Toggle("Auto-merge dependency PRs", isOn: $draft.dependencyAutoMerge)
                    Toggle("Auto-merge CI update PRs", isOn: $draft.ciAutoMerge)
                } header: {
                    Text("Updates")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Auto-merge requires GitHub repository auto-merge to be enabled and respects required checks and reviews.")
                        if model.automation?.scannerConfigured == false {
                            Text("The dependency scanner needs deployment configuration before scans can run.")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        MobileDependencyTargetsView(targets: $draft.targets, repoID: model.repo.id,
                                                    repoName: model.repo.repo ?? model.repo.fullName)
                    } label: {
                        LabeledContent("Project Directories") {
                            Text(draft.targets.map(\.displayDirectory).joined(separator: ", "))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Choose the root or each child project to include in dependency updates.")
                }

                Section {
                    Toggle("Scan dependencies for vulnerabilities", isOn: $draft.dependencySecurityEnabled)
                    Toggle("Email me about dependency vulnerabilities", isOn: $draft.dependencyNotifications)
                    Toggle("Scan GitHub Actions for vulnerabilities", isOn: $draft.ciSecurityEnabled)
                    Toggle("Email me about GitHub Actions vulnerabilities", isOn: $draft.ciNotifications)
                } header: {
                    Text("Security")
                } footer: {
                    Text("New findings go to your account email. Delivery failures appear in scan history and retry on the next scan.")
                }
            }
            .onChange(of: draft) { _, _ in MobileHaptics.buttonTap() }
            .disabled(saving)
            .navigationTitle("Automation Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        MobileHaptics.buttonTap()
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || !isDirty)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Could Not Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .mobileAutopilotLoadingDialog(saving, title: "Saving automation settings…")
        }
        .interactiveDismissDisabled(saving || isDirty)
        .onAppear {
            guard original == nil, let settings = model.automation?.settings else { return }
            draft = settings
            frequency = model.repo.scanFrequency
            original = (settings, frequency)
        }
    }

    private func save() async {
        guard !saving else { return }
        if Set(draft.targets.map(\.directory)).count != draft.targets.count {
            errorMessage = String(localized: "Each directory can only be configured once.")
            return
        }
        saving = true
        MobileHaptics.buttonTap()
        defer { saving = false }
        do {
            let saved = try await state.saveWatchedRepoAutomation(id: model.repo.id, settings: draft)
            model.didSave(saved)
            if frequency != model.repo.scanFrequency || model.repo.scheduleId == nil {
                try await state.updateWatchedRepoFrequency(id: model.repo.id, frequency: frequency)
                await model.refreshRepo(state)
            }
            MobileHaptics.connected()
            onSaved(String(localized: "Automation settings saved."))
            dismiss()
        } catch {
            MobileHaptics.connectionError()
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Dependency targets

private struct MobileDependencyTargetsView: View {
    @Binding var targets: [DependencyTarget]
    let repoID: String
    let repoName: String

    @State private var editing: EditingTarget?
    @State private var pendingRemoval: Int?

    struct EditingTarget: Identifiable {
        let index: Int?
        var target: DependencyTarget
        var id: String { index.map(String.init) ?? "new" }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(targets.enumerated()), id: \.element.directory) { index, target in
                    Button {
                        MobileHaptics.buttonTap()
                        editing = EditingTarget(index: index, target: target)
                    } label: {
                        LabeledContent {
                            Text(target.manager.displayName)
                        } label: {
                            Label(target.displayDirectory, systemImage: "folder").font(.body.monospaced())
                        }
                    }
                    .tint(.primary)
                    .swipeActions {
                        if targets.count > 1 {
                            Button("Remove", role: .destructive) { pendingRemoval = index }
                        }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = EditingTarget(index: index, target: target) }
                        if targets.count > 1 {
                            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = index }
                        }
                    }
                }
            } footer: {
                Text("Add the root (.) or each child project directory. For shared lockfiles, include the workspace root and each child project you want to update. Auto Detect picks the package manager from repository configuration and lockfiles.")
            }
        }
        .navigationTitle("Project Directories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Directory", systemImage: "plus") {
                    MobileHaptics.buttonTap()
                    editing = EditingTarget(index: nil, target: DependencyTarget())
                }
                .disabled(targets.count >= RepositoryAutomationSettings.maxTargets)
            }
        }
        .confirmationDialog("Remove this project directory from scanning?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Directory", role: .destructive) {
                if let index = pendingRemoval, targets.indices.contains(index), targets.count > 1 {
                    targets.remove(at: index)
                    MobileHaptics.connected()
                }
                pendingRemoval = nil
            }
        } message: {
            Text("The change applies when you save automation settings.")
        }
        .sheet(item: $editing) { item in
            MobileDependencyTargetEditor(
                target: item.target, isNew: item.index == nil, repoID: repoID, repoName: repoName,
                otherDirectories: Set(targets.enumerated().filter { $0.offset != item.index }.map(\.element.directory))
            ) { updated in
                if let index = item.index, targets.indices.contains(index) { targets[index] = updated }
                else { targets.append(updated) }
            }
            .mobileSheetPresentation()
        }
    }
}

private struct MobileDirectoryLevel: Hashable {
    let path: String
    let sha: String?
}

private struct MobileDependencyTargetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var target: DependencyTarget
    let isNew: Bool
    let repoID: String
    let repoName: String
    let otherDirectories: Set<String>
    let onDone: (DependencyTarget) -> Void

    @State private var path: [MobileDirectoryLevel] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: MobileDirectoryLevel(path: "", sha: nil)) {
                        LabeledContent("Directory") {
                            Text(target.displayDirectory).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                        }
                    }
                } footer: {
                    Text("Select a folder from the repository's default branch.")
                }
                Section {
                    Picker("Package Manager", selection: $target.manager) {
                        ForEach(DependencyManager.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("Explicit Node.js choices must match the committed lockfile. Python supports requirements, pipenv, Poetry and uv. Swift supports Package.swift.")
                }
            }
            .navigationTitle(isNew ? "Add Directory" : "Edit Directory")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MobileDirectoryLevel.self) { level in
                MobileDirectoryBrowser(level: level, repoID: repoID, repoName: repoName, selection: target.directory) { selected in
                    target.directory = selected
                    MobileHaptics.connected()
                    path = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
            }
            .alert("Invalid Directory", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func done() {
        guard RepositoryAutomationSettings.isValidDirectory(target.directory) else {
            errorMessage = String(localized: "Use a relative directory without wildcards or parent traversal.")
            MobileHaptics.connectionError()
            return
        }
        guard !otherDirectories.contains(target.directory) else {
            errorMessage = String(localized: "Each directory can only be configured once.")
            MobileHaptics.connectionError()
            return
        }
        MobileHaptics.buttonTap()
        onDone(target)
        dismiss()
    }
}

/// One folder level. Tapping a folder drills in; the current folder is chosen
/// from the toolbar, a row's swipe action, or its context menu.
private struct MobileDirectoryBrowser: View {
    @EnvironmentObject private var state: MobileAppState
    let level: MobileDirectoryLevel
    let repoID: String
    let repoName: String
    let selection: String
    let onSelect: (String) -> Void

    @State private var listing: RepositoryDirectoryListing?
    @State private var loading = false
    @State private var error: String?

    private var title: String {
        level.path.isEmpty ? String(localized: "\(repoName) (root)") : (level.path.split(separator: "/").last.map(String.init) ?? level.path)
    }

    var body: some View {
        Group {
            if let listing {
                List {
                    Section {
                        LabeledContent("Current Folder") {
                            HStack(spacing: 6) {
                                Text(level.path.isEmpty ? "." : level.path).font(.body.monospaced())
                                if selection == level.path {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Section("Folders") {
                        if listing.directories.isEmpty {
                            Text("No subfolders").foregroundStyle(.secondary)
                        }
                        ForEach(listing.directories) { directory in
                            let child = level.path.isEmpty ? directory.name : "\(level.path)/\(directory.name)"
                            let selectable = RepositoryAutomationSettings.isValidDirectory(child)
                            NavigationLink(value: MobileDirectoryLevel(path: child, sha: directory.sha)) {
                                HStack {
                                    Label(directory.name, systemImage: "folder")
                                    Spacer()
                                    if selection == child {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    } else if selection.hasPrefix(child + "/") {
                                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.tint)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if selectable {
                                    Button("Select", systemImage: "checkmark") { onSelect(child) }.tint(.accentColor)
                                }
                            }
                            .contextMenu {
                                if selectable {
                                    Button("Select Folder", systemImage: "checkmark.circle") { onSelect(child) }
                                }
                            }
                        }
                    }
                }
                .refreshable { await load() }
            } else if let error {
                ContentUnavailableView {
                    Label("Could Not Load Folders", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading folders…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Folder") { onSelect(level.path) }
                    .disabled(!RepositoryAutomationSettings.isValidDirectory(level.path))
            }
        }
        .task { if listing == nil { await load() } }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            listing = try await state.watchedRepoDirectories(id: repoID, sha: level.sha)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            MobileHaptics.connectionError()
        }
    }
}
