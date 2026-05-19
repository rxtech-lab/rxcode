import Foundation
import RxCodeCore

/// Discovers `xcodebuild` destinations for a given Xcode container + scheme.
/// Results are cached per (container, scheme) for the lifetime of the actor
/// so reopening the destination picker doesn't re-spawn `xcodebuild` every
/// time. The cache is best-effort — when in doubt, callers can pass
/// `forceRefresh: true`.
actor XcodeDestinationService {

    static let shared = XcodeDestinationService()

    private struct CacheKey: Hashable {
        let projectPath: String
        let container: String
        let scheme: String
    }

    private var cache: [CacheKey: [XcodeDestination]] = [:]

    func destinations(
        projectPath: String,
        container: String,
        isWorkspace: Bool,
        scheme: String,
        forceRefresh: Bool = false
    ) async -> [XcodeDestination] {
        let key = CacheKey(projectPath: projectPath, container: container, scheme: scheme)
        if !forceRefresh, let hit = cache[key] { return hit }

        guard !container.isEmpty, !scheme.isEmpty else { return [] }

        let containerPath = (projectPath as NSString).appendingPathComponent(container)
        let flag = isWorkspace ? "-workspace" : "-project"
        let output = await runProcess(
            executable: "/usr/bin/env",
            arguments: ["xcodebuild", flag, containerPath, "-scheme", scheme, "-showdestinations"],
            cwd: projectPath,
            timeoutSeconds: 20
        )
        let destinations = XcodeDestinationParser.parse(output)
        cache[key] = destinations
        return destinations
    }

    func invalidate(projectPath: String, container: String, scheme: String) {
        cache[CacheKey(projectPath: projectPath, container: container, scheme: scheme)] = nil
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        timeoutSeconds: Int
    ) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.environment = ProcessInfo.processInfo.environment

            let latch = OnceLatch()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if latch.set() { continuation.resume(returning: out) }
            }

            do {
                try process.run()
            } catch {
                if latch.set() { continuation.resume(returning: "") }
                return
            }

            Task.detached { [process] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
