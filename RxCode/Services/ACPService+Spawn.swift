import Foundation
import RxCodeCore
import os

// MARK: - Process Spawn

extension ACPService {

    func spawn(spec: ACPClientSpec, model: String?, cwd: String) async
        throws -> (Process, FileHandle, FileHandle, FileHandle)
    {
        let (executable, args, baseEnv) = try resolveLaunch(spec.launch)
        let allArgs = args + spec.extraArgs
        logger.info("[ACP] spawn exec=\(executable, privacy: .public) args=[\(allArgs.joined(separator: " "), privacy: .public)] cwd=\(cwd, privacy: .public)")

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
            logger.info("[ACP] spawn ok pid=\(process.processIdentifier) for \(spec.displayName, privacy: .public)")
        } catch {
            logger.error("[ACP] spawn FAILED exec=\(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return (process, stdinPipe.fileHandleForWriting,
                stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading)
    }

    func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let cachedShellPath {
            env["PATH"] = cachedShellPath
            return env
        }
        let shellPath = await readUserShellPath()
        if let shellPath, !shellPath.isEmpty {
            cachedShellPath = shellPath
            env["PATH"] = shellPath
            logger.info("[ACP] resolved login shell PATH (\(shellPath.split(separator: ":").count) entries)")
        } else {
            logger.warning("[ACP] could not read login shell PATH; using GUI PATH=\(env["PATH"] ?? "<unset>", privacy: .public)")
        }
        return env
    }

    func readUserShellPath() async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "print -rn -- $PATH"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (out?.isEmpty ?? true) ? nil : out
            } catch {
                return nil
            }
        }.value
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
