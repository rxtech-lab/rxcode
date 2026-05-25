import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Detail form

struct RunProfileDetailForm: View {
    @Binding var profile: RunProfile
    let project: Project

    @State var detectedMakeTargets: [String] = []
    @State var newPresetName: String = ""
    static let customTargetSentinel = "__rxcode_custom_target__"

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
        .onAppear {
            AnalyticsService.shared.log(.runProfileEditorOpened, parameters: [
                "project_id": project.id.uuidString,
                "profile_type": profile.type.rawValue,
            ])
        }
    }

    // MARK: - Command sections

    @ViewBuilder
    var bashCommandSection: some View {
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
    var xcodeCommandSection: some View {
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
    var makeCommandSection: some View {
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
    var makeDetectionKey: String {
        "\(profile.id.uuidString)|\(profile.make?.makefile ?? "")|\(profile.bash.workingDirectory)"
    }

    func refreshMakeTargets() async -> [String] {
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
    func targetField(make: Binding<MakeRunConfig>) -> some View {
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
}
