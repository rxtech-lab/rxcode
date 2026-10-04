import Foundation
import RxCodeCore
import os

// MARK: - Process Spawn

extension ACPService {

    func spawn(spec: ACPClientSpec, model: String?, cwd: String) async
        throws -> (Process, FileHandle, FileHandle, FileHandle)
    {
        let launchStartedAt = Date()
        let (executable, args, baseEnv) = try resolveLaunch(spec.launch)
        let allArgs = args + spec.extraArgs
        logger.info("[ACP] launch start client=\(spec.displayName, privacy: .public) exec=\(executable, privacy: .public) args=[\(allArgs.joined(separator: " "), privacy: .public)] cwd=\(cwd, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = allArgs
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = await resolvedEnvironment()
        env.merge(baseEnv) { _, new in new }
        env.merge(spec.extraEnv) { _, new in new }
        if let envVar = spec.modelEnvVar, let model, !model.isEmpty {
            env[envVar] = model
            logger.info("[ACP] spawn injecting model env \(envVar, privacy: .public)=\(model, privacy: .public)")
        }
        process.environment = env
        logger.info("[ACP] spawn PATH=\(env["PATH"] ?? "<unset>", privacy: .public)")

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let elapsed = Date().timeIntervalSince(launchStartedAt)
            logger.info("[ACP] process launched pid=\(process.processIdentifier) client=\(spec.displayName, privacy: .public) after=\(String(format: "%.2f", elapsed), privacy: .public)s")
        } catch {
            logger.error("[ACP] spawn FAILED exec=\(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return (process, stdinPipe.fileHandleForWriting,
                stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading)
    }

    /// The environment for spawned ACP clients: the GUI environment with the
    /// login-shell `PATH`.
    ///
    /// `ShellPathResolver` owns the caching (shared with the other backends,
    /// and remembered across launches), so asking it every time costs an actor
    /// hop and picks up a re-probed PATH without a relaunch.
    func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let shellPath = await readUserShellPath(), !shellPath.isEmpty {
            env["PATH"] = shellPath
        } else {
            logger.warning("[ACP] could not read login shell PATH; using GUI PATH=\(env["PATH"] ?? "<unset>", privacy: .public)")
        }
        return env
    }

    /// Prime the shell PATH cache so the first user message doesn't pay the
    /// `/bin/zsh -ilc` round trip in its critical path.
    func prewarm() async {
        _ = await resolvedEnvironment()
    }

    /// The user's login-shell `$PATH`, via the process-wide resolver: shared with
    /// the Claude and Codex backends and remembered across launches, so this no
    /// longer blocks a cooperative thread on `/bin/zsh -ilc`.
    func readUserShellPath() async -> String? {
        await ShellPathResolver.shared.current()
    }

    func resolveLaunch(_ launch: ACPClientSpec.LaunchKind)
        throws -> (String, [String], [String: String])
    {
        switch launch {
        case .npx(let package, let args, let env):
            return ("/usr/bin/env", ["npx", "-y", package] + args, env)
        case .uvx(let package, let args, let env):
            return ("/usr/bin/env", ["uvx", package] + args, env)
        case .binary(let path, let args, let env):
            return (path, args, env)
        case .custom(let command, let args, let env):
            return (command, args, env)
        }
    }
}
