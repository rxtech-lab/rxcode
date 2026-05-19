import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet for editing run profiles — JetBrains "Run/Debug Configurations"
/// equivalent. Left list of profiles, right form pinned to the selected one.
struct RunConfigurationsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var draft: [RunProfile] = []
    @State private var selectedId: UUID?
    @State private var detected: DetectedRunnables = .init()

    private var selectedIndex: Int? {
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

    private var header: some View {
        HStack {
            Text("Run/Debug Configurations")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var profileList: some View {
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
    private var detailPane: some View {
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

    private var footer: some View {
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
    private func profileRow(_ profile: RunProfile) -> some View {
        HStack {
            Image(systemName: iconName(for: profile.type))
                .foregroundStyle(ClaudeTheme.accent)
            Text(profile.name.isEmpty ? "Untitled" : profile.name)
        }
        .tag(profile.id)
    }

    private func iconName(for type: RunProfileType) -> String {
        switch type {
        case .xcode: return "hammer.fill"
        case .make: return "wrench.and.screwdriver.fill"
        case .bash: return "terminal"
        }
    }

    // MARK: - Add menu (detected runnables)

    private var addMenu: some View {
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

    private func addProfile(from runnable: DetectedRunnable? = nil) {
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

    private func addXcodeProfile() {
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

    private func addMakeProfile() {
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

    private func deleteSelected() {
        guard let idx = selectedIndex else { return }
        let removed = draft.remove(at: idx)
        if selectedId == removed.id {
            selectedId = draft.indices.contains(idx) ? draft[idx].id : draft.last?.id
        }
    }

    private func duplicateSelected() {
        guard let idx = selectedIndex else { return }
        var copy = draft[idx]
        copy.id = UUID()
        copy.name = copy.name + " (copy)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        draft.insert(copy, at: idx + 1)
        selectedId = copy.id
    }

    private func applyAndDismiss() {
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

// MARK: - Detail form

private struct RunProfileDetailForm: View {
    @Binding var profile: RunProfile
    let project: Project

    @State private var detectedMakeTargets: [String] = []
    private static let customTargetSentinel = "__rxcode_custom_target__"

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Type", selection: Binding(
                    get: { profile.type },
                    set: { newValue in
                        profile.type = newValue
                        if newValue == .xcode, profile.xcode == nil {
                            profile.xcode = XcodeRunConfig()
                        }
                        if newValue == .make, profile.make == nil {
                            profile.make = MakeRunConfig()
                        }
                    }
                )) {
                    ForEach(RunProfileType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
            } header: {
                Text("Configuration")
            }

            switch profile.type {
            case .bash:
                bashCommandSection
            case .xcode:
                xcodeCommandSection
            case .make:
                makeCommandSection
            }

            environmentsSection

            stepsSection(
                title: "Before Launch",
                steps: Binding(get: { profile.beforeSteps }, set: { profile.beforeSteps = $0 })
            )

            stepsSection(
                title: "After Launch",
                steps: Binding(get: { profile.afterSteps }, set: { profile.afterSteps = $0 })
            )
        }
        .formStyle(.grouped)
    }

    // MARK: - Command sections

    @ViewBuilder
    private var bashCommandSection: some View {
        Section {
            TextEditor(text: $profile.bash.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                )
            HStack {
                TextField("Working Directory", text: $profile.bash.workingDirectory, prompt: Text(project.path))
                Button("Browse…") {
                    pickDirectory { picked in
                        profile.bash.workingDirectory = picked
                    }
                }
                Button {
                    profile.bash.workingDirectory = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Reset to project root")
            }
        } header: {
            Text("Command")
        } footer: {
            Text("Absolute or project-relative path. Leave empty to use the project root.")
        }
    }

    @ViewBuilder
    private var xcodeCommandSection: some View {
        Section {
            let xcode = Binding(
                get: { profile.xcode ?? XcodeRunConfig() },
                set: { profile.xcode = $0 }
            )
            HStack {
                TextField(
                    "Project / Workspace",
                    text: xcode.container,
                    prompt: Text("RxCode.xcodeproj")
                )
                .font(.system(.body, design: .monospaced))
                Button("Browse…") {
                    pickXcodeContainer { name, isWorkspace in
                        var c = xcode.wrappedValue
                        c.container = name
                        c.isWorkspace = isWorkspace
                        xcode.wrappedValue = c
                    }
                }
            }
            Toggle("Use Workspace (.xcworkspace)", isOn: xcode.isWorkspace)
            TextField("Scheme", text: xcode.scheme, prompt: Text("RxCode"))
                .font(.system(.body, design: .monospaced))
            TextField("Configuration", text: xcode.configuration, prompt: Text("Debug"))
                .font(.system(.body, design: .monospaced))
            Picker("Action", selection: xcode.action) {
                ForEach(XcodeAction.allCases, id: \.self) { action in
                    Text(action.rawValue.capitalized).tag(action)
                }
            }
            LabeledContent("Destination") {
                HStack(spacing: 6) {
                    Text(xcode.wrappedValue.selectedDestination?.displayName ?? "Any Mac (default)")
                        .foregroundStyle(.secondary)
                    if xcode.wrappedValue.selectedDestination != nil {
                        Button {
                            var c = xcode.wrappedValue
                            c.selectedDestination = nil
                            xcode.wrappedValue = c
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear destination — pick again from the toolbar")
                    }
                }
            }
        } header: {
            Text("Xcode")
        } footer: {
            Text("Build runs `xcodebuild build`. Run builds, then launches the produced .app (macOS) or installs + launches on the selected simulator. Pick the destination from the Run toolbar.")
        }
    }

    @ViewBuilder
    private var makeCommandSection: some View {
        Section {
            let make = Binding(
                get: { profile.make ?? MakeRunConfig() },
                set: { profile.make = $0 }
            )
            HStack {
                TextField(
                    "Makefile (optional)",
                    text: make.makefile,
                    prompt: Text("Makefile")
                )
                .font(.system(.body, design: .monospaced))
                Button("Browse…") {
                    pickFile { picked in
                        var c = make.wrappedValue
                        c.makefile = picked
                        make.wrappedValue = c
                    }
                }
                Button {
                    var c = make.wrappedValue
                    c.makefile = ""
                    make.wrappedValue = c
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Use default Makefile lookup")
            }
            targetField(make: make)
            TextField(
                "Arguments (optional)",
                text: make.arguments,
                prompt: Text("VAR=value -j8")
            )
            .font(.system(.body, design: .monospaced))
            HStack {
                TextField("Working Directory", text: $profile.bash.workingDirectory, prompt: Text(project.path))
                Button("Browse…") {
                    pickDirectory { picked in
                        profile.bash.workingDirectory = picked
                    }
                }
                Button {
                    profile.bash.workingDirectory = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Reset to project root")
            }
        } header: {
            Text("Make")
        } footer: {
            Text("Runs `make [-f <Makefile>] <target> [arguments]`. Leave Makefile empty to use the default lookup (Makefile / makefile / GNUmakefile).")
        }
        .task(id: makeDetectionKey) {
            detectedMakeTargets = await refreshMakeTargets()
        }
    }

    /// Cache key for re-parsing the Makefile when its path or the working
    /// directory changes.
    private var makeDetectionKey: String {
        "\(profile.id.uuidString)|\(profile.make?.makefile ?? "")|\(profile.bash.workingDirectory)"
    }

    private func refreshMakeTargets() async -> [String] {
        let projectRoot = project.path
        let makefile = profile.make?.makefile ?? ""
        let workingDirRaw = profile.bash.workingDirectory
        return await Task.detached { () -> [String] in
            let fm = FileManager.default
            func resolve(_ p: String, against base: String) -> String {
                if p.isEmpty { return base }
                if p.hasPrefix("/") { return p }
                return (base as NSString).appendingPathComponent(p)
            }
            let workingDir = workingDirRaw.isEmpty
                ? projectRoot
                : resolve(workingDirRaw, against: projectRoot)

            if !makefile.isEmpty {
                // Picker produces project-relative paths; the executor resolves
                // relative to working dir. Try both so the dropdown works
                // regardless of which the user typed.
                let candidates = [
                    resolve(makefile, against: projectRoot),
                    resolve(makefile, against: workingDir),
                ]
                for path in candidates where fm.fileExists(atPath: path) {
                    return RunProfileDetector.makeTargets(atPath: path)
                }
                return []
            }
            if let result = RunProfileDetector.defaultMakeTargets(inDirectory: workingDir) {
                return result.targets
            }
            return RunProfileDetector.defaultMakeTargets(inDirectory: projectRoot)?.targets ?? []
        }.value
    }

    @ViewBuilder
    private func targetField(make: Binding<MakeRunConfig>) -> some View {
        let current = make.wrappedValue.target
        let targets = detectedMakeTargets
        let isCustom = !targets.isEmpty && !current.isEmpty && !targets.contains(current)

        if targets.isEmpty {
            TextField("Target", text: make.target, prompt: Text("build"))
                .font(.system(.body, design: .monospaced))
        } else {
            Picker("Target", selection: Binding(
                get: {
                    if current.isEmpty { return "" }
                    return isCustom ? Self.customTargetSentinel : current
                },
                set: { newValue in
                    var c = make.wrappedValue
                    if newValue == Self.customTargetSentinel {
                        if targets.contains(c.target) { c.target = "" }
                    } else {
                        c.target = newValue
                    }
                    make.wrappedValue = c
                }
            )) {
                if current.isEmpty {
                    Text("Select a target…").tag("")
                }
                ForEach(targets, id: \.self) { t in
                    Text(t).tag(t)
                }
                Divider()
                Text("Custom…").tag(Self.customTargetSentinel)
            }
            .font(.system(.body, design: .monospaced))

            if isCustom {
                TextField("Custom target", text: make.target, prompt: Text("build"))
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private func pickXcodeContainer(onPick: @escaping (String, Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xcodeproj") ?? .package,
            UTType(filenameExtension: "xcworkspace") ?? .package,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name: String
        let root = (project.path as NSString).standardizingPath
        let std = (url.path as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            name = String(std.dropFirst(root.count + 1))
        } else {
            name = std
        }
        onPick(name, url.pathExtension == "xcworkspace")
    }

    // MARK: - Environments

    @State private var newPresetName: String = ""

    private var activePresetIndex: Int? {
        guard let id = profile.bash.activePresetId ?? profile.bash.environments.first?.id else { return nil }
        return profile.bash.environments.firstIndex { $0.id == id }
    }

    @ViewBuilder
    private var environmentsSection: some View {
        Section {
            LabeledContent("Preset") {
                HStack {
                    Picker("", selection: Binding(
                        get: { profile.bash.activePresetId ?? profile.bash.environments.first?.id },
                        set: { profile.bash.activePresetId = $0 }
                    )) {
                        if profile.bash.environments.isEmpty {
                            Text("None").tag(UUID?.none)
                        } else {
                            ForEach(profile.bash.environments) { preset in
                                Text(preset.name.isEmpty ? "Untitled" : preset.name)
                                    .tag(UUID?.some(preset.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button {
                        addPreset()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Preset")
                    Button {
                        deleteActivePreset()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(profile.bash.environments.isEmpty)
                    .help("Delete Preset")
                }
            }
            if let idx = activePresetIndex {
                presetEditor(idx: idx)
            }
        } header: {
            Text("Environments")
        } footer: {
            if activePresetIndex == nil {
                Text("Add a preset (e.g. \"dev\", \"prod\") to configure environment variables.")
            }
        }
    }

    @ViewBuilder
    private func presetEditor(idx: Int) -> some View {
        let preset = Binding(
            get: { profile.bash.environments[idx] },
            set: { profile.bash.environments[idx] = $0 }
        )

        TextField("Preset Name", text: preset.name, prompt: Text("dev / prod / beta"))

        Toggle("Load from .env file", isOn: preset.loadFromFile)

        if preset.wrappedValue.loadFromFile {
            LabeledContent("Env File") {
                HStack {
                    TextField(".env", text: Binding(
                        get: { preset.wrappedValue.envFilePath ?? "" },
                        set: { preset.wrappedValue.envFilePath = $0 }
                    ))
                    Button("Browse…") {
                        pickFile { picked in
                            preset.wrappedValue.envFilePath = picked
                        }
                    }
                }
            }
        }

        Toggle("Manual key/value pairs", isOn: preset.useManualKV)

        if preset.wrappedValue.useManualKV {
            manualKVTable(preset: preset)
        }
    }

    private func addPreset() {
        let preset = EnvironmentPreset(
            name: profile.bash.environments.isEmpty ? "dev" : "preset \(profile.bash.environments.count + 1)"
        )
        profile.bash.environments.append(preset)
        profile.bash.activePresetId = preset.id
    }

    private func deleteActivePreset() {
        guard let idx = activePresetIndex else { return }
        let removed = profile.bash.environments.remove(at: idx)
        if profile.bash.activePresetId == removed.id {
            profile.bash.activePresetId = profile.bash.environments.first?.id
        }
    }

    @ViewBuilder
    private func manualKVTable(preset: Binding<EnvironmentPreset>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row with column titles and add button
            HStack(spacing: 8) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Text("Value")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    preset.wrappedValue.manualVars.append(EnvVar())
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Add Variable")
            }

            if preset.wrappedValue.manualVars.isEmpty {
                HStack {
                    Spacer()
                    Text("No environment variables defined")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                // Variable rows
                ForEach(preset.wrappedValue.manualVars.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("API_KEY", text: Binding(
                            get: { preset.wrappedValue.manualVars[i].key },
                            set: { preset.wrappedValue.manualVars[i].key = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140)

                        TextField("value", text: Binding(
                            get: { preset.wrappedValue.manualVars[i].value },
                            set: { preset.wrappedValue.manualVars[i].value = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            preset.wrappedValue.manualVars.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove Variable")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Before / after steps

    @ViewBuilder
    private func stepsSection(title: String, steps: Binding<[RunStep]>) -> some View {
        Section {
            if steps.wrappedValue.isEmpty {
                Text("There are no tasks to run \(title.lowercased()).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(steps.wrappedValue.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { steps.wrappedValue[i].type },
                            set: { steps.wrappedValue[i].type = $0 }
                        )) {
                            ForEach(RunStepType.allCases, id: \.self) { t in
                                Text(t.rawValue.capitalized).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        TextField("command", text: Binding(
                            get: { steps.wrappedValue[i].command },
                            set: { steps.wrappedValue[i].command = $0 }
                        ))
                        .font(.system(.body, design: .monospaced))
                        Button {
                            if i > 0 { steps.wrappedValue.swapAt(i, i - 1) }
                        } label: { Image(systemName: "arrow.up") }
                            .disabled(i == 0)
                        Button {
                            if i < steps.wrappedValue.count - 1 { steps.wrappedValue.swapAt(i, i + 1) }
                        } label: { Image(systemName: "arrow.down") }
                            .disabled(i == steps.wrappedValue.count - 1)
                        Button {
                            steps.wrappedValue.remove(at: i)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Menu {
                    Button("Bash") {
                        steps.wrappedValue.append(RunStep(type: .bash, command: ""))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - File pickers

    private func pickDirectory(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            onPick(displayPath(for: url))
        }
    }

    private func pickFile(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            onPick(displayPath(for: url))
        }
    }

    /// If the picked URL is inside the project root, return a project-relative
    /// path; otherwise return the absolute path.
    private func displayPath(for url: URL) -> String {
        let absolute = url.path
        let root = (project.path as NSString).standardizingPath
        let std = (absolute as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            return "./" + String(std.dropFirst(root.count + 1))
        }
        return std
    }
}
