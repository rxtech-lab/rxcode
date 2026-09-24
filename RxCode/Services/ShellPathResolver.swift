import Foundation
import os

/// Process-wide resolver for the user's interactive login-shell `PATH`.
///
/// Every agent backend (Claude, Codex, ACP) needs the same answer: the `PATH` a
/// login shell would hand a CLI, so spawned agents find `node`, `nvm`, and
/// friends. Producing it means running `/bin/zsh -ilc`, which sources the user's
/// full profile and costs *seconds* on a machine with nvm/rbenv/gvm init — paid
/// three times over, on the launch critical path.
///
/// This actor resolves it once per process, and remembers the result in
/// `UserDefaults` so only the very first launch on a machine ever waits for the
/// shell. Later launches start from the remembered value and re-probe in the
/// background, so a changed profile is picked up without blocking anyone.
actor ShellPathResolver {
    static let shared = ShellPathResolver()

    private static let defaultsKey = "resolvedLoginShellPath"
    private static let shellExecutable = "/bin/zsh"

    private let logger = Logger(subsystem: "com.claudework", category: "ShellPath")

    private var resolved: String?
    private var inFlight: Task<String?, Never>?
    private var didStartBackgroundRefresh = false
    /// Set when a probe came back empty. A shell that can't report a PATH won't
    /// start reporting one mid-session, and retrying costs a full shell startup
    /// on every agent spawn — so ask again only on an explicit `refresh()`.
    private var probeFailed = false

    /// `PATH` remembered from a previous launch, if any.
    nonisolated static var remembered: String? {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Best available login-shell `PATH`.
    ///
    /// Returns the remembered value immediately when there is one (refreshing it
    /// in the background); only a machine's first launch waits on the shell.
    func current() async -> String? {
        if let resolved { return resolved }
        if let remembered = Self.remembered {
            resolved = remembered
            startBackgroundRefresh()
            return remembered
        }
        guard !probeFailed else { return nil }
        return await probe()
    }

    /// Run the shell probe now, replacing the remembered value. Callers that
    /// need the freshest answer (e.g. after the user installs a CLI) use this.
    @discardableResult
    func refresh() async -> String? {
        await probe()
    }

    // MARK: - Private

    private func startBackgroundRefresh() {
        guard !didStartBackgroundRefresh else { return }
        didStartBackgroundRefresh = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.refresh()
        }
    }

    /// Single-flight around the shell spawn: concurrent callers (the three
    /// backends all prewarm at launch) share one `/bin/zsh -ilc` round trip.
    private func probe() async -> String? {
        if let inFlight { return await inFlight.value }

        let task = Task<String?, Never> { await Self.readLoginShellPath() }
        inFlight = task
        let value = await task.value
        inFlight = nil

        guard let value, !value.isEmpty else {
            probeFailed = true
            logger.warning("Login shell PATH probe returned nothing; keeping the GUI PATH")
            return nil
        }
        probeFailed = false
        resolved = value
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        logger.info("Resolved login shell PATH (entries=\(value.split(separator: ":").count))")
        return value
    }

    private static func readLoginShellPath() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellExecutable)
            process.arguments = ["-ilc", "print -rn -- $PATH"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            // `terminationHandler` fires on a background queue, so the shell runs
            // without blocking a cooperative thread. It never fires when `run()`
            // throws, so exactly one of the two paths resumes the continuation.
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (output?.isEmpty ?? true) ? nil : output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
