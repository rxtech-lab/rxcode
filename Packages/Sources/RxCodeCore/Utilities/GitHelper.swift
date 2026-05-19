import Foundation

public enum GitHelper {
    public static func run(_ args: [String], at path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "",
            "PAGER": "",
        ]) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func currentBranch(at path: String) async -> String? {
        guard let result = await run(["symbolic-ref", "--short", "HEAD"], at: path) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Checks out an existing branch at `path`. Returns the combined git output
    /// on failure, or nil on success.
    public static func checkout(branch: String, at path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", branch]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "",
            "PAGER": "",
        ]) { _, new in new }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch { return "\(error)" }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        if process.terminationStatus == 0 { return nil }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") +
                       (String(data: errData, encoding: .utf8) ?? "")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "git checkout exited \(process.terminationStatus)" : trimmed
    }

    /// Returns local branch names ordered by most recent commit first.
    public static func listLocalBranches(at path: String) async -> [String] {
        guard let result = await run(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/"],
            at: path
        ) else {
            return []
        }
        return result
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
