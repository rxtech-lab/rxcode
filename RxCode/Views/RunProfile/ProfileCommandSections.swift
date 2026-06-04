import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared command-configuration form sections — the Type picker plus the
/// per-type command editors (bash / xcode / make / package) with their
/// auto-detection. Reused by both `RunProfileDetailForm` and
/// `HookProfileDetailForm` so the typed editors live in exactly one place.
///
/// Operates on bindings to the individual config structs rather than a whole
/// `RunProfile`/`HookProfile`, so it is agnostic to which model it edits.
struct ProfileCommandSections: View {
    /// Used only to scope detection cache keys to the edited profile/hook.
    let profileID: UUID
    let project: Project
    @Binding var type: RunProfileType
    @Binding var bash: BashRunConfig
    @Binding var xcode: XcodeRunConfig?
    @Binding var make: MakeRunConfig?
    @Binding var package: PackageRunConfig?

    @State private var detectedMakeTargets: [String] = []
    @State private var detectedPackageScripts: [String] = []
    @State private var installedPackageManagers: [PackageManager] = []
    static let customTargetSentinel = "__rxcode_custom_target__"
    static let customScriptSentinel = "__rxcode_custom_script__"

    var body: some View {
        Group {
            typeSection

            switch type {
            case .bash:
                bashCommandSection
            case .xcode:
                xcodeCommandSection
            case .make:
                makeCommandSection
            case .packageScript:
                packageCommandSection
            }
        }
    }

    // MARK: - Type

    @ViewBuilder
    private var typeSection: some View {
        Section {
            Picker("Type", selection: Binding(
                get: { type },
                set: { newValue in
                    type = newValue
                    if newValue == .xcode, xcode == nil {
                        xcode = XcodeRunConfig()
                    }
                    if newValue == .make, make == nil {
                        make = MakeRunConfig()
                    }
                    if newValue == .packageScript, package == nil {
                        package = PackageRunConfig()
                    }
                }
            )) {
                ForEach(RunProfileType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
        } header: {
            Text("Type")
        }
    }

    // MARK: - Command sections

    @ViewBuilder
    var bashCommandSection: some View {
        Section {
            TextEditor(text: $bash.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                )
            HStack {
                TextField("Working Directory", text: $bash.workingDirectory, prompt: Text(project.path))
                Button("Browse…") {
                    pickDirectory { picked in
                        bash.workingDirectory = picked
                    }
                }
                Button {
                    bash.workingDirectory = ""
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
                get: { self.xcode ?? XcodeRunConfig() },
                set: { self.xcode = $0 }
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
                get: { self.make ?? MakeRunConfig() },
                set: { self.make = $0 }
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
                TextField("Working Directory", text: $bash.workingDirectory, prompt: Text(project.path))
                Button("Browse…") {
                    pickDirectory { picked in
                        bash.workingDirectory = picked
                    }
                }
                Button {
                    bash.workingDirectory = ""
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
        "\(profileID.uuidString)|\(make?.makefile ?? "")|\(bash.workingDirectory)"
    }

    func refreshMakeTargets() async -> [String] {
        let projectRoot = project.path
        let makefile = make?.makefile ?? ""
        let workingDirRaw = bash.workingDirectory
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

    // MARK: - Package

    @ViewBuilder
    var packageCommandSection: some View {
        Section {
            let pkg = Binding(
                get: { self.package ?? PackageRunConfig() },
                set: { self.package = $0 }
            )
            Picker("Package Manager", selection: pkg.packageManager) {
                ForEach(PackageManager.allCases, id: \.self) { manager in
                    let installed = installedPackageManagers.isEmpty
                        || installedPackageManagers.contains(manager)
                    Text(installed ? manager.displayName : "\(manager.displayName) (not installed)")
                        .tag(manager)
                        .disabled(!installed)
                }
            }
            scriptField(pkg: pkg)
            TextField(
                "Arguments (optional)",
                text: pkg.arguments,
                prompt: Text("-- --port 3000")
            )
            .font(.system(.body, design: .monospaced))
            HStack {
                TextField("Working Directory", text: $bash.workingDirectory, prompt: Text(project.path))
                Button("Browse…") {
                    pickDirectory { picked in
                        bash.workingDirectory = picked
                    }
                }
                Button {
                    bash.workingDirectory = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Reset to project root")
            }
        } header: {
            Text("Node.js")
        } footer: {
            Text("Runs `\(packageCommandPreview)`. Arguments are appended after the script — use `-- <flags>` to forward flags through npm/pnpm.")
        }
        .task(id: packageDetectionKey) {
            detectedPackageScripts = await refreshPackageScripts()
            installedPackageManagers = await RunProfileDetector.detectInstalledPackageManagers()
        }
    }

    /// `<manager> run <script> [args]` shown in the footer for clarity.
    var packageCommandPreview: String {
        let pkg = package ?? PackageRunConfig()
        let script = pkg.script.isEmpty ? "<script>" : pkg.script
        var preview = "\(pkg.packageManager.runPrefix) \(script)"
        let args = pkg.arguments.trimmingCharacters(in: .whitespaces)
        if !args.isEmpty { preview += " \(args)" }
        return preview
    }

    /// Cache key for re-reading package.json scripts when the working directory
    /// changes.
    var packageDetectionKey: String {
        "\(profileID.uuidString)|\(bash.workingDirectory)"
    }

    func refreshPackageScripts() async -> [String] {
        let projectRoot = project.path
        let workingDirRaw = bash.workingDirectory
        return await Task.detached { () -> [String] in
            func resolve(_ p: String, against base: String) -> String {
                if p.isEmpty { return base }
                if p.hasPrefix("/") { return p }
                return (base as NSString).appendingPathComponent(p)
            }
            let dir = workingDirRaw.isEmpty
                ? projectRoot
                : resolve(workingDirRaw, against: projectRoot)
            return RunProfileDetector.packageScriptNames(inDirectory: dir)
        }.value
    }

    @ViewBuilder
    func scriptField(pkg: Binding<PackageRunConfig>) -> some View {
        let current = pkg.wrappedValue.script
        let scripts = detectedPackageScripts
        let isCustom = !scripts.isEmpty && !current.isEmpty && !scripts.contains(current)

        if scripts.isEmpty {
            TextField("Script", text: pkg.script, prompt: Text("dev"))
                .font(.system(.body, design: .monospaced))
        } else {
            Picker("Script", selection: Binding(
                get: {
                    if current.isEmpty { return "" }
                    return isCustom ? Self.customScriptSentinel : current
                },
                set: { newValue in
                    var c = pkg.wrappedValue
                    if newValue == Self.customScriptSentinel {
                        if scripts.contains(c.script) { c.script = "" }
                    } else {
                        c.script = newValue
                    }
                    pkg.wrappedValue = c
                }
            )) {
                if current.isEmpty {
                    Text("Select a script…").tag("")
                }
                ForEach(scripts, id: \.self) { s in
                    Text(s).tag(s)
                }
                Divider()
                Text("Custom…").tag(Self.customScriptSentinel)
            }
            .font(.system(.body, design: .monospaced))

            if isCustom {
                TextField("Custom script", text: pkg.script, prompt: Text("dev"))
                    .font(.system(.body, design: .monospaced))
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
