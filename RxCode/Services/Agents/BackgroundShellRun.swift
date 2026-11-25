import Foundation

/// One background shell command an agent started: runs `/bin/zsh -lc` in a
/// folder, keeps the tail of its combined output, and stops on timeout or
/// cancel.
nonisolated final class BackgroundShellRun: @unchecked Sendable {
    struct Outcome: Sendable {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
        let cancelled: Bool
    }

    /// Bytes of output kept; older output is dropped.
    static let outputLimit = 64 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var droppedBytes = 0
    private var process: Process?
    private var wasCancelled = false
    private var didTimeOut = false

    let command: String
    let workingDirectory: String
    let timeout: Duration

    init(command: String, workingDirectory: String, timeout: Duration) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// Runs the command to completion. Safe to call once.
    func run() async -> Outcome {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["RXCODE_AGENT_BACKGROUND_TASK"] = "1"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }

        let cancelledEarly = lock.withLock {
            self.process = process
            return wasCancelled
        }
        if cancelledEarly {
            return Outcome(exitCode: -1, output: "", timedOut: false, cancelled: true)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                self.append(Data("Failed to start: \(error.localizedDescription)\n".utf8))
                continuation.resume(returning: -1)
            }
        }
        // Drain anything written just before exit.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { append(rest) }

        return lock.withLock {
            Outcome(exitCode: exitCode, output: tailText(), timedOut: didTimeOut, cancelled: wasCancelled)
        }
    }

    /// Starts the timeout clock; call alongside `run()`.
    func startTimeout() -> Task<Void, Never> {
        Task.detached { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.stop(timedOut: true)
        }
    }

    func cancel() { stop(timedOut: false) }

    /// The output so far, for live inspection.
    func currentOutput() -> String {
        lock.withLock { tailText() }
    }

    private func stop(timedOut: Bool) {
        let process: Process? = lock.withLock {
            if timedOut { didTimeOut = true } else { wasCancelled = true }
            return self.process
        }
        guard let process, process.isRunning else { return }
        process.terminate()
        // Escalate when the command ignores SIGTERM.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > Self.outputLimit {
                let overflow = buffer.count - Self.outputLimit
                droppedBytes += overflow
                buffer.removeFirst(overflow)
            }
        }
    }

    /// Caller holds `lock`.
    private func tailText() -> String {
        let text = String(decoding: buffer, as: UTF8.self)
        return droppedBytes > 0 ? "…(\(droppedBytes) earlier bytes omitted)\n" + text : text
    }
}
