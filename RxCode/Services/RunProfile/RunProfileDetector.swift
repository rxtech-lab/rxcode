import Foundation
import RxCodeCore

// `RunnableSource`, `DetectedRunnable`, and `DetectedRunnables` live in
// `RxCodeCore` so the sync protocol can carry detection results to mobile.

/// Read-only scanner that surfaces Xcode schemes, npm scripts, and Make
/// targets at a project root. Errors are swallowed — a broken `xcodebuild`
/// or unreadable file yields an empty list, not a thrown error.
@MainActor
final class RunProfileDetector {
    func detect(in projectPath: String) async -> DetectedRunnables {
        async let xcode = detectXcode(at: projectPath)
        async let npm = detectPackageScripts(at: projectPath)
        async let make = detectMake(at: projectPath)
        return await DetectedRunnables(xcode: xcode, npm: npm, make: make)
    }

    // MARK: - Xcode

    private func detectXcode(at root: String) async -> [DetectedRunnable] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted()
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted()

        let flag: String
        let container: String
        if let ws = workspaces.first {
            flag = "-workspace"
            container = ws
        } else if let proj = projects.first {
            flag = "-project"
            container = proj
        } else {
            return []
        }

        let containerPath = (root as NSString).appendingPathComponent(container)
        let (stdout, code) = await runProcess(
            executable: "/usr/bin/env",
            arguments: ["xcodebuild", "-list", "-json", flag, containerPath],
            cwd: root,
            timeoutSeconds: 8
        )
        guard code == 0, let data = stdout.data(using: .utf8) else { return [] }

        struct XcodeList: Decodable {
            struct Workspace: Decodable { let schemes: [String]? }
            struct Project: Decodable { let schemes: [String]? }
            let workspace: Workspace?
            let project: Project?
        }

        guard let parsed = try? JSONDecoder().decode(XcodeList.self, from: data) else { return [] }
        let schemes = parsed.workspace?.schemes ?? parsed.project?.schemes ?? []

        let isWorkspace = (flag == "-workspace")
        return schemes.map { name in
            let cmd = "xcodebuild \(flag) \"\(container)\" -scheme \"\(name)\" build"
            let xcode = XcodeRunConfig(
                container: container,
                isWorkspace: isWorkspace,
                scheme: name,
                configuration: "Debug",
                action: .run
            )
            return DetectedRunnable(
                id: "xcode:\(name)",
                source: .xcode,
                displayName: name,
                command: cmd,
                xcode: xcode
            )
        }
    }

    // MARK: - Package scripts (npm / yarn / pnpm / bun / deno)

    /// Scan `package.json` `scripts` (and, for Deno projects, `deno.json` /
    /// `deno.jsonc` `tasks`) and surface each as a `.packageScript` runnable
    /// carrying the package manager inferred from lock files.
    private func detectPackageScripts(at root: String) async -> [DetectedRunnable] {
        let names = Self.packageScriptNames(inDirectory: root)
        guard !names.isEmpty else { return [] }

        let manager = detectPackageManager(at: root)
        return names.map { name in
            let cfg = PackageRunConfig(packageManager: manager, script: name)
            return DetectedRunnable(
                id: "npm:\(name)",
                source: .npm,
                displayName: name,
                command: "\(manager.runPrefix) \(name)",
                package: cfg
            )
        }
    }

    /// Decode the keys of a top-level object field (`scripts` or `tasks`) from a
    /// JSON file. Returns an empty array if the file is missing or unparseable.
    static func scriptNames(atPath path: String, key: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json[key] as? [String: Any]
        else { return [] }
        return Array(entries.keys)
    }

    /// Sorted script/task names found in `package.json` (falling back to
    /// `deno.json` / `deno.jsonc` tasks) inside `directory`. Used by the editor
    /// to back the script dropdown.
    static func packageScriptNames(inDirectory directory: String) -> [String] {
        let path = directory as NSString
        var names = scriptNames(atPath: path.appendingPathComponent("package.json"), key: "scripts")
        if names.isEmpty {
            for file in ["deno.json", "deno.jsonc"] {
                let denoNames = scriptNames(atPath: path.appendingPathComponent(file), key: "tasks")
                if !denoNames.isEmpty {
                    names = denoNames
                    break
                }
            }
        }
        return names.sorted()
    }

    /// Infer the package manager from lock files / manifests present at `root`.
    private func detectPackageManager(at root: String) -> PackageManager {
        let fm = FileManager.default
        let path = root as NSString
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: path.appendingPathComponent(name)) }
        if exists("pnpm-lock.yaml") { return .pnpm }
        if exists("yarn.lock") { return .yarn }
        if exists("bun.lockb") || exists("bun.lock") { return .bun }
        if exists("deno.lock") || exists("deno.json") || exists("deno.jsonc") { return .deno }
        return .npm
    }

    /// Detect which package managers are installed on this machine. Runs a
    /// single interactive zsh so nvm/asdf/Homebrew PATH entries are visible
    /// (matching the PATH-resolution trick used by `RunTaskExecutor`).
    static func detectInstalledPackageManagers() async -> [PackageManager] {
        let names = PackageManager.allCases.map(\.executable).joined(separator: " ")
        let script = "for c in \(names); do command -v $c >/dev/null 2>&1 && echo $c; done"
        let (stdout, _) = await RunProfileDetector().runProcess(
            executable: "/bin/zsh",
            arguments: ["-ic", script],
            cwd: NSHomeDirectory(),
            timeoutSeconds: 8
        )
        let found = Set(stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init))
        return PackageManager.allCases.filter { found.contains($0.executable) }
    }

    // MARK: - Makefile

    private func detectMake(at root: String) async -> [DetectedRunnable] {
        let fm = FileManager.default
        let candidates = ["Makefile", "makefile", "GNUmakefile"]
        let path = root as NSString
        guard let chosen = candidates.first(where: { fm.fileExists(atPath: path.appendingPathComponent($0)) }),
              let content = try? String(contentsOfFile: path.appendingPathComponent(chosen), encoding: .utf8)
        else { return [] }

        let targets = Self.parseMakeTargets(content)
        // Default Makefile lookup (`make`) finds the same file we picked here,
        // so leave `makefile` empty unless the user picked a non-default name.
        let isDefaultName = (chosen == "Makefile" || chosen == "makefile" || chosen == "GNUmakefile")
        let makefileName = isDefaultName ? "" : chosen
        return targets.map { name in
            DetectedRunnable(
                id: "make:\(name)",
                source: .make,
                displayName: name,
                command: "make \(name)",
                make: MakeRunConfig(makefile: makefileName, target: name)
            )
        }
    }

    /// Parse the `make` targets from a Makefile at `path`. Returns an empty
    /// array if the file is missing or unreadable.
    static func makeTargets(atPath path: String) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parseMakeTargets(content)
    }

    /// Try the standard Makefile names inside `root` and parse the first one
    /// that exists. Returns the resolved path alongside the targets.
    static func defaultMakeTargets(inDirectory root: String) -> (path: String, targets: [String])? {
        let fm = FileManager.default
        let candidates = ["Makefile", "makefile", "GNUmakefile"]
        let dir = root as NSString
        for name in candidates {
            let full = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: full) {
                return (full, makeTargets(atPath: full))
            }
        }
        return nil
    }

    static func parseMakeTargets(_ content: String) -> [String] {
        // Target lines look like `name:` or `name: deps` at column 0 (no leading
        // tab/space — those are recipe lines). Skip pattern rules (`%.o:`),
        // special targets (`.PHONY:`), variable assignments (`X := y`).
        var seen = Set<String>()
        var result: [String] = []
        let pattern = #"^([A-Za-z0-9_./+-]+)\s*:(?!=)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.hasPrefix("\t") || rawLine.hasPrefix(" ") { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let nsLine = rawLine as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: rawLine, range: range),
                  match.numberOfRanges >= 2
            else { continue }

            let name = nsLine.substring(with: match.range(at: 1))
            if name.hasPrefix(".") { continue }  // .PHONY, .DEFAULT, etc.
            if name.contains("%") { continue }   // pattern rule
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    // MARK: - Process helper

    private func runProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        timeoutSeconds: Int
    ) async -> (stdout: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.environment = ProcessInfo.processInfo.environment

            let resumed = ManagedAtomicFlag()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if resumed.setIfUnset() {
                    continuation.resume(returning: (out, process.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                if resumed.setIfUnset() {
                    continuation.resume(returning: ("", -1))
                }
                return
            }

            Task.detached { [process] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

/// Tiny one-shot latch used to guard `continuation.resume` against double
/// firing when both the termination handler and the timeout race.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}
