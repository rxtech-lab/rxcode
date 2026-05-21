import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet for editing run profiles — JetBrains "Run/Debug Configurations"
/// equivalent. Left list of profiles, right form pinned to the selected one.
struct RunConfigurationsView: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState
    @Environment(\.dismiss) var dismiss

    let project: Project

    @State var draft: [RunProfile] = []
    @State var selectedId: UUID?
    @State var detected: DetectedRunnables = .init()

    var selectedIndex: Int? {
        guard let id = selectedId else { return nil }
        return draft.firstIndex { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                profileList
                    .frame(minWidth: 220, idealWidth: 240, maxHeight: .infinity)
                detailPane
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560, idealHeight: 620)
        .onAppear {
            draft = appState.runProfiles(for: project.id)
            selectedId = windowState.selectedRunProfileId ?? draft.first?.id
        }
        .task {
            detected = await RunProfileDetector().detect(in: project.path)
        }
    }

    // MARK: - Sections

    var header: some View {
        HStack {
            Text("Run/Debug Configurations")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var profileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                addMenu
                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedId == nil)
                .help("Delete Profile")
                Button {
                    duplicateSelected()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selectedId == nil)
                .help("Duplicate Profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()

            if draft.isEmpty {
                VStack {
                    Spacer()
                    Text("No profiles yet")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text("Click + to add one.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedId) {
                    let xcodeProfiles = draft.filter { $0.type == .xcode }
                    let makeProfiles = draft.filter { $0.type == .make }
                    let bashProfiles = draft.filter { $0.type == .bash }

                    if !xcodeProfiles.isEmpty {
                        Section("Xcode") {
                            ForEach(xcodeProfiles) { profile in
                                profileRow(profile)
                            }
                        }
                    }
                    if !makeProfiles.isEmpty {
                        Section("Make") {
                            ForEach(makeProfiles) { profile in
                                profileRow(profile)
                            }
                        }
                    }
                    if !bashProfiles.isEmpty {
                        Section("Bash") {
                            ForEach(bashProfiles) { profile in
                                profileRow(profile)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
    }

    @ViewBuilder
    var detailPane: some View {
        if let idx = selectedIndex {
            RunProfileDetailForm(
                profile: $draft[idx],
                project: project
            )
            .id(draft[idx].id)
        } else {
            VStack {
                Spacer()
                Text("Select or add a profile to edit")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                applyAndDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    func profileRow(_ profile: RunProfile) -> some View {
        HStack {
            Image(systemName: iconName(for: profile.type))
                .foregroundStyle(ClaudeTheme.accent)
            Text(profile.name.isEmpty ? "Untitled" : profile.name)
        }
        .tag(profile.id)
    }

    func iconName(for type: RunProfileType) -> String {
        switch type {
        case .xcode: return "hammer.fill"
        case .make: return "wrench.and.screwdriver.fill"
        case .bash: return "terminal"
        }
    }

    // MARK: - Add menu (detected runnables)

    var addMenu: some View {
        Menu {
            Section("Xcode") {
                Button {
                    addXcodeProfile()
                } label: {
                    Label("Empty Xcode Configuration", systemImage: "hammer.fill")
                }
                ForEach(detected.xcode) { runnable in
                    Button {
                        addProfile(from: runnable)
                    } label: {
                        Label(runnable.displayName, systemImage: "hammer.fill")
                    }
                }
            }

            Section("Make") {
                Button {
                    addMakeProfile()
                } label: {
                    Label("Empty Make Configuration", systemImage: "wrench.and.screwdriver.fill")
                }
                ForEach(detected.make) { runnable in
                    Button {
                        addProfile(from: runnable)
                    } label: {
                        Label(runnable.displayName, systemImage: "wrench.and.screwdriver.fill")
                    }
                }
            }

            Section("Bash") {
                Button {
                    addProfile()
                } label: {
                    Label("Empty Bash Configuration", systemImage: "terminal")
                }
                ForEach(detected.npm) { runnable in
                    Button {
                        addProfile(from: runnable)
                    } label: {
                        Label(runnable.displayName, systemImage: "shippingbox.fill")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Profile")
    }

    // MARK: - Actions

    func addProfile(from runnable: DetectedRunnable? = nil) {
        let now = Date()
        if let xcode = runnable?.xcode {
            let new = RunProfile(
                projectId: project.id,
                name: runnable?.displayName ?? "New Xcode Configuration",
                type: .xcode,
                xcode: xcode,
                createdAt: now,
                updatedAt: now
            )
            draft.append(new)
            selectedId = new.id
            return
        }
        if let make = runnable?.make {
            let new = RunProfile(
                projectId: project.id,
                name: runnable?.displayName ?? "New Make Configuration",
                type: .make,
                make: make,
                createdAt: now,
                updatedAt: now
            )
            draft.append(new)
            selectedId = new.id
            return
        }
        let new = RunProfile(
            projectId: project.id,
            name: runnable?.displayName ?? "New Bash Configuration",
            bash: BashRunConfig(command: runnable?.command ?? ""),
            createdAt: now,
            updatedAt: now
        )
        draft.append(new)
        selectedId = new.id
    }

    func addXcodeProfile() {
        let now = Date()
        let firstDetected = detected.xcode.first?.xcode
        let new = RunProfile(
            projectId: project.id,
            name: "New Xcode Configuration",
            type: .xcode,
            xcode: firstDetected ?? XcodeRunConfig(),
            createdAt: now,
            updatedAt: now
        )
        draft.append(new)
        selectedId = new.id
    }

    func addMakeProfile() {
        let now = Date()
        let firstDetected = detected.make.first?.make
        let new = RunProfile(
            projectId: project.id,
            name: "New Make Configuration",
            type: .make,
            make: firstDetected ?? MakeRunConfig(),
            createdAt: now,
            updatedAt: now
        )
        draft.append(new)
        selectedId = new.id
    }

    func deleteSelected() {
        guard let idx = selectedIndex else { return }
        let removed = draft.remove(at: idx)
        if selectedId == removed.id {
            selectedId = draft.indices.contains(idx) ? draft[idx].id : draft.last?.id
        }
    }

    func duplicateSelected() {
        guard let idx = selectedIndex else { return }
        var copy = draft[idx]
        copy.id = UUID()
        copy.name = copy.name + " (copy)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        draft.insert(copy, at: idx + 1)
        selectedId = copy.id
    }

    func applyAndDismiss() {
        // Stamp updatedAt on whatever changed.
        let now = Date()
        let stamped = draft.map { profile -> RunProfile in
            var p = profile
            p.updatedAt = now
            return p
        }
        appState.setRunProfiles(stamped, for: project.id)
        if let sel = selectedId, stamped.contains(where: { $0.id == sel }) {
            windowState.selectedRunProfileId = sel
        } else {
            windowState.selectedRunProfileId = stamped.first?.id
        }
        dismiss()
    }
}
