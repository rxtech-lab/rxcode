import RxCodeCore
import RxCodeSync
import SwiftUI

/// Editor sheet for a single run profile on mobile. Scheme/Target fields are
/// backed by desktop auto-detection; the file fields (working directory, Xcode
/// project, Makefile) open the remote folder file-sheet.
struct MobileRunProfileEditorView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunProfile
    @State private var activePicker: FolderPick?
    let projectID: UUID

    /// Sentinel tag for the "Custom…" entry in detection-backed pickers.
    private static let customTag = "__rxcode_custom_value__"

    /// Which field's remote file-sheet is currently open.
    private enum FolderPick: Int, Identifiable {
        case workingDirectory
        case xcodeContainer
        case makefile
        var id: Int { rawValue }
    }

    /// Desktop-detected runnables for this project, used to back the Scheme and
    /// Target pickers. Empty until the detection request resolves.
    private var detected: DetectedRunnables {
        state.detectedRunnablesByProject[projectID] ?? DetectedRunnables()
    }

    private var projectPath: String? {
        state.projects.first { $0.id == projectID }?.path
    }

    init(profile: RunProfile, projectID: UUID) {
        self._draft = State(initialValue: profile)
        self.projectID = projectID
    }

    var body: some View {
        Form {
            Section("Configuration") {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: Binding(
                    get: { draft.type },
                    set: { type in
                        draft.type = type
                        if type == .xcode, draft.xcode == nil { draft.xcode = XcodeRunConfig() }
                        if type == .make, draft.make == nil { draft.make = MakeRunConfig() }
                    }
                )) {
                    Text("Bash").tag(RunProfileType.bash)
                    Text("Xcode").tag(RunProfileType.xcode)
                    Text("Make").tag(RunProfileType.make)
                }
            }

            switch draft.type {
            case .bash:
                bashSection
            case .xcode:
                xcodeSection
            case .make:
                makeSection
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Run Profile" : draft.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    saved.projectId = projectID
                    saved.updatedAt = Date()
                    Task {
                        await state.saveRunProfile(saved, projectID: projectID)
                        dismiss()
                    }
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $activePicker) { pick in
            folderPickerSheet(for: pick)
                .mobileSheetPresentation()
        }
        .onAppear {
            AnalyticsService.shared.log(.runProfileEditorOpened, parameters: [
                "project_id": projectID.uuidString,
                "profile_type": String(describing: draft.type),
            ])
        }
    }

    /// Builds the remote file-sheet for whichever field requested it. The
    /// chosen path is converted to a project-relative value so it matches what
    /// desktop auto-detection stores.
    @ViewBuilder
    private func folderPickerSheet(for pick: FolderPick) -> some View {
        switch pick {
        case .workingDirectory:
            RemoteFolderPickerView(mode: .pickFolder(
                title: "Working Directory",
                startPath: projectPath,
                onSelect: { draft.bash.workingDirectory = projectRelativePath($0) }
            ))
            .environmentObject(state)
        case .xcodeContainer:
            RemoteFolderPickerView(mode: .pickEntry(.init(
                title: "Xcode Project",
                startPath: projectPath,
                includeFiles: false,
                isTarget: { $0.name.hasSuffix(".xcodeproj") || $0.name.hasSuffix(".xcworkspace") },
                onSelect: { path in
                    var xcode = draft.xcode ?? XcodeRunConfig()
                    xcode.container = projectRelativePath(path)
                    xcode.isWorkspace = path.hasSuffix(".xcworkspace")
                    draft.xcode = xcode
                }
            )))
            .environmentObject(state)
        case .makefile:
            RemoteFolderPickerView(mode: .pickEntry(.init(
                title: "Makefile",
                startPath: projectPath,
                includeFiles: true,
                isTarget: { !$0.isDirectory },
                onSelect: { path in
                    var make = draft.make ?? MakeRunConfig()
                    make.makefile = projectRelativePath(path)
                    draft.make = make
                }
            )))
            .environmentObject(state)
        }
    }

    /// Converts an absolute desktop path to one relative to the project root
    /// when it lives inside the project, so stored config matches desktop
    /// detection (which uses names like `App.xcodeproj`). Paths outside the
    /// project are kept absolute.
    private func projectRelativePath(_ absolute: String) -> String {
        guard let root = projectPath, !root.isEmpty else { return absolute }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if absolute == normalizedRoot { return "" }
        let prefix = normalizedRoot + "/"
        if absolute.hasPrefix(prefix) { return String(absolute.dropFirst(prefix.count)) }
        return absolute
    }

    /// Trailing "Browse" button that opens the remote file-sheet for `pick`.
    private func browseButton(_ pick: FolderPick) -> some View {
        Button {
            activePicker = pick
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Browse")
    }

    private var bashSection: some View {
        Section("Command") {
            TextEditor(text: $draft.bash.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
            workingDirectoryField
        }
    }

    private var xcodeSection: some View {
        Section("Xcode") {
            let xcode = Binding(
                get: { draft.xcode ?? XcodeRunConfig() },
                set: { draft.xcode = $0 }
            )
            HStack {
                TextField("Project / Workspace", text: xcode.container, prompt: Text("App.xcodeproj"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                browseButton(.xcodeContainer)
            }
            Toggle("Use Workspace", isOn: xcode.isWorkspace)
            schemeField(xcode)
            TextField("Configuration", text: xcode.configuration)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Picker("Action", selection: xcode.action) {
                ForEach(XcodeAction.allCases, id: \.self) { action in
                    Text(action.rawValue.capitalized).tag(action)
                }
            }
            TextField("Destination", text: xcode.destination, prompt: Text("Optional xcodebuild destination"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }

    private var makeSection: some View {
        Section("Make") {
            let make = Binding(
                get: { draft.make ?? MakeRunConfig() },
                set: { draft.make = $0 }
            )
            HStack {
                TextField("Makefile", text: make.makefile, prompt: Text("Makefile"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                browseButton(.makefile)
            }
            targetField(make)
            TextField("Arguments", text: make.arguments)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            workingDirectoryField
        }
    }

    /// Working directory field shared by the bash and make sections, with a
    /// "Browse" button that opens the remote folder file-sheet.
    private var workingDirectoryField: some View {
        HStack {
            TextField(
                "Working Directory",
                text: $draft.bash.workingDirectory,
                prompt: Text("Project root")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            browseButton(.workingDirectory)
        }
    }

    /// Scheme field: a picker over desktop-detected Xcode schemes, falling back
    /// to a free-text field when nothing was detected or "Custom…" is chosen.
    @ViewBuilder
    private func schemeField(_ xcode: Binding<XcodeRunConfig>) -> some View {
        let schemes = detected.xcode.compactMap { $0.xcode?.scheme }
        if schemes.isEmpty {
            TextField("Scheme", text: xcode.scheme)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        } else {
            Picker("Scheme", selection: detectionSelection(xcode.scheme, options: schemes)) {
                ForEach(schemes, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag(Self.customTag)
            }
            if !schemes.contains(xcode.wrappedValue.scheme) {
                TextField("Custom Scheme", text: xcode.scheme)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
    }

    /// Target field: a picker over desktop-detected Make targets, falling back
    /// to a free-text field when nothing was detected or "Custom…" is chosen.
    @ViewBuilder
    private func targetField(_ make: Binding<MakeRunConfig>) -> some View {
        let targets = detected.make.compactMap { $0.make?.target }
        if targets.isEmpty {
            TextField("Target", text: make.target)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        } else {
            Picker("Target", selection: detectionSelection(make.target, options: targets)) {
                ForEach(targets, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag(Self.customTag)
            }
            if !targets.contains(make.wrappedValue.target) {
                TextField("Custom Target", text: make.target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
    }

    /// Bridges a free-text `String` binding to a picker selection: reports the
    /// "Custom…" sentinel whenever the current value isn't a detected option.
    private func detectionSelection(_ value: Binding<String>, options: [String]) -> Binding<String> {
        Binding(
            get: { options.contains(value.wrappedValue) ? value.wrappedValue : Self.customTag },
            set: { newValue in
                if newValue == Self.customTag {
                    if options.contains(value.wrappedValue) {
                        value.wrappedValue = ""
                    }
                } else {
                    value.wrappedValue = newValue
                }
            }
        )
    }
}
