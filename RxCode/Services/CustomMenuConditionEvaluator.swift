#if os(macOS)
import Foundation
import CryptoKit
import os
import RxCodeCore

/// Compiles and runs user-authored Swift "show condition" scripts for custom
/// context-menu items (`CustomMenuItemRecord` with `conditionType == .swiftScript`).
///
/// The user writes a single function:
/// ```swift
/// func checkShowMenu(context: Context) async throws -> Bool { ... }
/// ```
/// We wrap it in a generated harness (`conditionHarness`) that defines the
/// `Context` struct — exposing the project name/path and `shell`/`git` helpers —
/// and an async `@main` runner that decodes the context from the environment,
/// `try await`s the user's function, and prints `"true"`/`"false"`.
///
/// Compilation goes through `xcrun swiftc`; the resulting binary is cached by a
/// SHA-256 of the full harness+script source so a given script is compiled once.
/// Evaluation just runs that cached binary with the context in its environment.
///
/// Every failure mode (no toolchain, compile error, runtime crash, timeout,
/// non-`true` output) resolves to **show** the item — a broken condition never
/// silently hides a menu entry the user configured.
actor CustomMenuConditionEvaluator {
    private let logger = Logger(subsystem: "com.rxlab.RxCode", category: "MenuCondition")

    /// Hard cap on how long a single condition may run before we give up and show
    /// the item. Keeps a runaway script from wedging menu building.
    private let evaluationTimeout: TimeInterval = 3

    struct CompileResult: Sendable {
        let success: Bool
        /// Compiler diagnostics (stderr), surfaced to the editor on failure.
        let diagnostics: String
        let binaryPath: String?
    }

    struct Context: Sendable {
        let projectName: String
        let projectPath: String
        let gitHubRepo: String
        let branch: String
        let sessionId: String

        var environment: [String: String] {
            [
                "RXC_PROJECT_NAME": projectName,
                "RXC_PROJECT_PATH": projectPath,
                "RXC_GITHUB_REPO": gitHubRepo,
                "RXC_BRANCH": branch,
                "RXC_SESSION_ID": sessionId,
            ]
        }
    }

    // MARK: - Public API

    /// Compile `script` (the user's `checkShowMenu` function). Returns whether it
    /// built and, on failure, the compiler diagnostics. On success the binary is
    /// left in the cache so a later `evaluate` runs instantly.
    func compile(script: String) async -> CompileResult {
        let source = Self.conditionHarness(userScript: script)
        let binaryURL = cachedBinaryURL(forSource: source)

        // Already compiled this exact source — nothing to do.
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            return CompileResult(success: true, diagnostics: "", binaryPath: binaryURL.path)
        }

        do {
            return try await compile(source: source, to: binaryURL)
        } catch {
            return CompileResult(success: false, diagnostics: "Failed to run the Swift compiler: \(error.localizedDescription)", binaryPath: nil)
        }
    }

    /// Evaluate a script for `context`, returning whether the item should be shown.
    /// Compiles on demand if the binary isn't cached. Any failure → `true` (show).
    func evaluate(script: String, context: Context) async -> Bool {
        let source = Self.conditionHarness(userScript: script)
        let binaryURL = cachedBinaryURL(forSource: source)

        logger.debug("[ContextMenuCondition] evaluate: project=\(context.projectName, privacy: .public) branch=\(context.branch, privacy: .public) session=\(context.sessionId, privacy: .public) cachedBinary=\(binaryURL.lastPathComponent, privacy: .public)")

        if !FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            logger.debug("[ContextMenuCondition] evaluate: binary not cached — compiling")
            let result = await compile(script: script)
            guard result.success else {
                logger.warning("[ContextMenuCondition] Menu condition failed to compile; showing item by default. diagnostics=\(result.diagnostics, privacy: .public)")
                return true
            }
        }

        do {
            // Inject a resolved login PATH so the rc-less harness shell still finds
            // user-installed tools (git is in the default PATH, but gh/node/etc. may
            // not be).
            var environment = context.environment
            environment["PATH"] = await loginPath()
            let output = try await run(binaryURL, environment: environment, timeout: evaluationTimeout)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Anything other than an explicit "false" shows the item.
            let show = trimmed != "false"
            logger.debug("[ContextMenuCondition] evaluate: rawOutput=\(output, privacy: .public) trimmed=\(trimmed, privacy: .public) -> show=\(show, privacy: .public)")
            return show
        } catch {
            logger.warning("[ContextMenuCondition] Menu condition evaluation failed (\(error.localizedDescription, privacy: .public)); showing item by default.")
            return true
        }
    }

    // MARK: - Compilation

    private func compile(source: String, to binaryURL: URL) async throws -> CompileResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RxCodeMenuConditions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The file must NOT be named main.swift, or `@main` is rejected.
        let sourceURL = tempDir.appendingPathComponent("condition.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Compile to a temp output first, then move into place — so a half-written
        // binary never looks cached.
        let stagedBinary = tempDir.appendingPathComponent("condition.bin")
        // `-parse-as-library` is required: a single compiled .swift file is
        // otherwise treated as top-level code, which conflicts with `@main`.
        let result = try await run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-Onone", "-parse-as-library", sourceURL.path, "-o", stagedBinary.path],
            captureStdErr: true,
            timeout: 60
        )

        guard FileManager.default.isExecutableFile(atPath: stagedBinary.path) else {
            return CompileResult(success: false, diagnostics: result.isEmpty ? "Compilation failed." : result, binaryPath: nil)
        }

        try? FileManager.default.removeItem(at: binaryURL)
        try FileManager.default.moveItem(at: stagedBinary, to: binaryURL)
        return CompileResult(success: true, diagnostics: "", binaryPath: binaryURL.path)
    }

    /// Cache location for a compiled binary, keyed by a hash of its full source.
    private func cachedBinaryURL(forSource source: String) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RxCode/menu-conditions", isDirectory: true)
        return dir.appendingPathComponent(hash)
    }

    // MARK: - PATH resolution

    private var cachedLoginPath: String?

    /// The user's login `PATH`, resolved once via a login shell and cached. Falls
    /// back to a sensible default if resolution fails. stderr (profile noise) is
    /// discarded; we take the last stdout line in case the profile echoes.
    private func loginPath() async -> String {
        if let cachedLoginPath { return cachedLoginPath }
        let fallback = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        do {
            let out = try await run(
                URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", "echo $PATH"],
                timeout: 10
            )
            let line = out.split(separator: "\n").map(String.init).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let resolved = line.isEmpty ? fallback : line
            cachedLoginPath = resolved
            return resolved
        } catch {
            cachedLoginPath = fallback
            return fallback
        }
    }

    // MARK: - Process runner

    /// Run an executable to completion (or `timeout` seconds, whichever comes
    /// first) and return its captured output. Throws `Timeout` if it overruns.
    private func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        captureStdErr: Bool = false,
        timeout: TimeInterval
    ) async throws -> String {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = captureStdErr ? pipe : FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        proc.environment = env

        try proc.run()

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    proc.terminationHandler = { _ in continuation.resume() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil // sentinel: timed out
            }

            defer { group.cancelAll() }
            let first = try await group.next() ?? nil
            if let output = first {
                return output
            }
            // Timed out before the process finished.
            if proc.isRunning { proc.terminate() }
            throw Timeout()
        }
    }

    private struct Timeout: Error {}

    // MARK: - Harness

    /// Wrap the user's `checkShowMenu` function in a self-contained Swift program.
    /// The file is compiled as-is; the `Context` API documented here is the public
    /// contract the editor and the AI-generate prompt describe to the user.
    static func conditionHarness(userScript: String) -> String {
        """
        import Foundation

        /// The context handed to a show-condition script. Exposes the current
        /// project and helpers to run CLI commands inside it.
        struct Context {
            let projectName: String
            let projectPath: String
            let gitHubRepo: String
            let branch: String
            let sessionId: String

            /// Run a shell command in the project directory and return its trimmed
            /// stdout. The shell is started with `-d -f` so NO startup files run:
            /// many setups override `cd` or change the working directory in their rc
            /// files, which would otherwise break this. The working directory is set
            /// directly on the process instead, and `PATH` is injected by the host so
            /// user tools still resolve. stderr is discarded so it can't pollute the
            /// result.
            @discardableResult
            func shell(_ command: String) async throws -> String {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-d", "-f", "-c", command]
                proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                return (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            /// Run `git` with the given arguments in the project directory.
            @discardableResult
            func git(_ args: String...) async throws -> String {
                let quoted = args
                    .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\\\''") + "'" }
                    .joined(separator: " ")
                return try await shell("git " + quoted)
            }
        }

        // ---- User script ----
        \(userScript)
        // ---- End user script ----

        @main
        struct __RxCodeConditionRunner {
            static func main() async {
                let env = ProcessInfo.processInfo.environment
                let context = Context(
                    projectName: env["RXC_PROJECT_NAME"] ?? "",
                    projectPath: env["RXC_PROJECT_PATH"] ?? "",
                    gitHubRepo: env["RXC_GITHUB_REPO"] ?? "",
                    branch: env["RXC_BRANCH"] ?? "",
                    sessionId: env["RXC_SESSION_ID"] ?? ""
                )
                do {
                    let show = try await checkShowMenu(context: context)
                    print(show ? "true" : "false")
                } catch {
                    FileHandle.standardError.write(Data("condition error: \\(error)".utf8))
                    print("true")
                }
            }
        }
        """
    }

    /// The starter template offered in the editor for a new Swift-script condition.
    static let starterScript = """
    func checkShowMenu(context: Context) async throws -> Bool {
        // Return true to show the menu item, false to hide it.
        // `context` exposes: projectName, projectPath, gitHubRepo, branch, sessionId,
        // and async helpers `shell(_:)` / `git(_:)` that run in the project directory.
        //
        // Example — only show when there are uncommitted git changes:
        let status = try await context.git("status", "--porcelain")
        return !status.isEmpty
    }
    """
}
#endif
