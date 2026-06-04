import RxCodeCore
import RxCodeSync
import SwiftUI

struct MobileRunProfilesView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var editingProfile: RunProfile?

    private var project: Project? {
        state.projects.first { $0.id == projectID }
    }

    private var profiles: [RunProfile] {
        state.runProfiles(for: projectID).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var tasks: [MobileRunTaskSnapshot] {
        state.runTasks(for: projectID)
    }

    /// Desktop-detected runnables for this project, or an empty set until the
    /// detection request resolves.
    private var detected: DetectedRunnables {
        state.detectedRunnablesByProject[projectID] ?? DetectedRunnables()
    }

    var body: some View {
        List {
            if !tasks.isEmpty {
                Section("Runs") {
                    ForEach(tasks) { task in
                        runTaskRow(task)
                    }
                }
            }

            Section("Profiles") {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No Run Profiles",
                        systemImage: "play.rectangle",
                        description: Text("Create a profile to run a command on your Mac.")
                    )
                } else {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
        .navigationTitle(project?.name ?? "Run Profiles")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
        .task {
            await state.requestRunnableDetection(projectID: projectID)
        }
        .refreshable {
            await state.refreshSnapshot()
            await state.requestRunnableDetection(projectID: projectID)
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                MobileRunProfileEditorView(profile: profile, projectID: projectID)
                    .environmentObject(state)
            }
            .mobileSheetPresentation()
        }
        .alert("Run Profile Error", isPresented: Binding(
            get: { state.lastRunProfileError != nil },
            set: { if !$0 { state.lastRunProfileError = nil } }
        )) {
            Button("OK", role: .cancel) { state.lastRunProfileError = nil }
        } message: {
            Text(state.lastRunProfileError ?? "")
        }
    }

    private func profileRow(_ profile: RunProfile) -> some View {
        let task = state.runningTask(projectID: projectID, profileID: profile.id)
        return HStack(spacing: 12) {
            Image(systemName: iconName(for: profile.type))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                    .lineLimit(1)
                Text(profileSubtitle(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let task {
                Button {
                    Task { await state.stopRunTask(task) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button {
                    Task { await state.runProfile(projectID: projectID, profileID: profile.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingProfile = profile
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await state.deleteRunProfile(projectID: projectID, profileID: profile.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Edit") { editingProfile = profile }
            Button("Duplicate") {
                var copy = profile
                copy.id = UUID()
                copy.name = profile.name + " (copy)"
                copy.createdAt = Date()
                copy.updatedAt = Date()
                Task { await state.saveRunProfile(copy, projectID: projectID) }
            }
            Button("Delete", role: .destructive) {
                Task { await state.deleteRunProfile(projectID: projectID, profileID: profile.id) }
            }
        }
    }

    private func runTaskRow(_ task: MobileRunTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(task.profileName, systemImage: task.isRunning ? "play.circle.fill" : "checkmark.circle")
                    .foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
                Spacer()
                Text(task.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !task.commandPreview.isEmpty {
                Text(task.commandPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let output = task.terminalOutputTail, !output.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }

            if task.isRunning {
                Button(role: .destructive) {
                    Task { await state.stopRunTask(task) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func iconName(for type: RunProfileType) -> String {
        switch type {
        case .bash: return "terminal"
        case .xcode: return "hammer.fill"
        case .make: return "wrench.and.screwdriver.fill"
        case .packageScript: return "shippingbox.fill"
        }
    }

    private func profileSubtitle(_ profile: RunProfile) -> String {
        switch profile.type {
        case .bash:
            return profile.bash.command.isEmpty ? "Bash command" : profile.bash.command
        case .xcode:
            let xcode = profile.xcode ?? XcodeRunConfig()
            return [xcode.container, xcode.scheme, xcode.action.rawValue].filter { !$0.isEmpty }.joined(separator: " · ")
        case .make:
            let make = profile.make ?? MakeRunConfig()
            return ["make", make.target, make.arguments].filter { !$0.isEmpty }.joined(separator: " ")
        case .packageScript:
            let pkg = profile.package ?? PackageRunConfig()
            return [pkg.packageManager.runPrefix, pkg.script, pkg.arguments].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// "+" menu: blank profiles plus everything the desktop auto-detected for
    /// this project. Picking a detected entry materializes a pre-filled profile.
    private var addMenu: some View {
        Menu {
            Section("New") {
                Button {
                    editingProfile = Self.newProfile(projectID: projectID, type: .bash)
                } label: {
                    Label("Bash Configuration", systemImage: "terminal")
                }
                Button {
                    editingProfile = Self.newProfile(projectID: projectID, type: .xcode)
                } label: {
                    Label("Xcode Configuration", systemImage: "hammer.fill")
                }
                Button {
                    editingProfile = Self.newProfile(projectID: projectID, type: .make)
                } label: {
                    Label("Make Configuration", systemImage: "wrench.and.screwdriver.fill")
                }
                Button {
                    editingProfile = Self.newProfile(projectID: projectID, type: .packageScript)
                } label: {
                    Label("Node.js Configuration", systemImage: "shippingbox.fill")
                }
            }

            if !detected.xcode.isEmpty {
                Section("Detected · Xcode") {
                    ForEach(detected.xcode) { runnable in
                        Button {
                            editingProfile = Self.profile(from: runnable, projectID: projectID)
                        } label: {
                            Label(runnable.displayName, systemImage: "hammer.fill")
                        }
                    }
                }
            }
            if !detected.make.isEmpty {
                Section("Detected · Make") {
                    ForEach(detected.make) { runnable in
                        Button {
                            editingProfile = Self.profile(from: runnable, projectID: projectID)
                        } label: {
                            Label(runnable.displayName, systemImage: "wrench.and.screwdriver.fill")
                        }
                    }
                }
            }
            if !detected.npm.isEmpty {
                Section("Detected · Scripts") {
                    ForEach(detected.npm) { runnable in
                        Button {
                            editingProfile = Self.profile(from: runnable, projectID: projectID)
                        } label: {
                            Label(runnable.displayName, systemImage: "shippingbox.fill")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private static func newProfile(projectID: UUID, type: RunProfileType) -> RunProfile {
        let now = Date()
        switch type {
        case .bash:
            return RunProfile(
                projectId: projectID,
                name: "New Bash Configuration",
                type: .bash,
                bash: BashRunConfig(),
                createdAt: now,
                updatedAt: now
            )
        case .xcode:
            return RunProfile(
                projectId: projectID,
                name: "New Xcode Configuration",
                type: .xcode,
                xcode: XcodeRunConfig(),
                createdAt: now,
                updatedAt: now
            )
        case .make:
            return RunProfile(
                projectId: projectID,
                name: "New Make Configuration",
                type: .make,
                make: MakeRunConfig(),
                createdAt: now,
                updatedAt: now
            )
        case .packageScript:
            return RunProfile(
                projectId: projectID,
                name: "New Node.js Configuration",
                type: .packageScript,
                package: PackageRunConfig(),
                createdAt: now,
                updatedAt: now
            )
        }
    }

    /// Materialize a desktop-detected runnable into an editable `RunProfile`,
    /// mirroring the desktop's `RunConfigurationsView.addProfile(from:)`.
    private static func profile(from runnable: DetectedRunnable, projectID: UUID) -> RunProfile {
        let now = Date()
        if let xcode = runnable.xcode {
            return RunProfile(
                projectId: projectID,
                name: runnable.displayName,
                type: .xcode,
                xcode: xcode,
                createdAt: now,
                updatedAt: now
            )
        }
        if let make = runnable.make {
            return RunProfile(
                projectId: projectID,
                name: runnable.displayName,
                type: .make,
                make: make,
                createdAt: now,
                updatedAt: now
            )
        }
        if let package = runnable.package {
            return RunProfile(
                projectId: projectID,
                name: runnable.displayName,
                type: .packageScript,
                package: package,
                createdAt: now,
                updatedAt: now
            )
        }
        return RunProfile(
            projectId: projectID,
            name: runnable.displayName,
            bash: BashRunConfig(command: runnable.command),
            createdAt: now,
            updatedAt: now
        )
    }
}
