import Foundation
import RxCodeCore
import os

/// Result of running a single hook command.
struct HookRunResult: Sendable {
    let output: String
    let exitCode: Int32
    var isError: Bool { exitCode != 0 }
}

/// Lightweight `Process`-based runner for lifecycle hooks. Unlike `RunService`
/// (which is bound to a SwiftTerm terminal view for interactive output), hooks
/// run headless and we only need their combined stdout/stderr and exit code so
/// the result can be shown in chat and, for start hooks, injected into the
/// agent's context.
enum HookService {
    private static let logger = Logger(subsystem: "com.claudework", category: "HookService")

    /// Hard cap on captured output so a chatty hook can't blow up the message
    /// store or the injected system prompt.
    private static let maxOutputBytes = 64 * 1024

    /// Run a bash hook. Resolves working directory and environment with the same
    /// helpers `RunService` uses, then executes the command under a login zsh so
    /// the user's PATH (bun, pnpm, pyenv, …) is available — matching how
    /// `RunTaskExecutor` and the interactive terminal source PATH.
    static func run(_ profile: HookProfile, project: Project) async -> HookRunResult {
        let command = profile.bash.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return HookRunResult(output: "", exitCode: 0)
        }

        let cwd = RunTaskExecutor.resolveWorkingDirectory(
            profile.bash.workingDirectory,
            projectPath: project.path
        )
        let preset = profile.bash.environments.first { $0.id == profile.bash.activePresetId }
            ?? profile.bash.environments.first
        let environment = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: project.path,
            baseEnvironment: ProcessInfo.processInfo.environment
        )

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                logger.error("Hook '\(profile.name, privacy: .public)' failed to launch: \(error.localizedDescription, privacy: .public)")
                return HookRunResult(output: "Failed to launch hook: \(error.localizedDescription)", exitCode: -1)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let clipped = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data[...]
            var output = String(decoding: clipped, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if data.count > maxOutputBytes {
                output += "\n… (output truncated)"
            }
            return HookRunResult(output: output, exitCode: process.terminationStatus)
        }.value
    }
}
