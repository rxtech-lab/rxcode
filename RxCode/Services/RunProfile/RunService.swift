import AppKit
import Foundation
import Observation
import RxCodeCore
import SwiftTerm
import os

/// Status of a `RunTask`. Drives the status badge in the inspector dropdown
/// and the toolbar stop-button visibility.
enum RunTaskStatus: Sendable, Equatable {
    case running
    case succeeded
    case failed(Int32)
    case signaled(Int32)
    case stopped

    var isTerminal: Bool {
        switch self {
        case .running: return false
        case .succeeded, .failed, .signaled, .stopped: return true
        }
    }

    var label: String {
        switch self {
        case .running: return "running"
        case .succeeded: return "done"
        case .failed(let code): return "exit \(code)"
        case .signaled(let sig): return "signal \(sig)"
        case .stopped: return "stopped"
        }
    }
}

/// Decode the raw `waitpid(2)` status that SwiftTerm passes through. POSIX
/// status is a packed 16-bit value: bits 8–15 are the exit code when the
/// process exited normally; bits 0–6 hold the signal when it was killed.
/// Without this decode, a normal `exit 1` shows up as `256`, etc.
enum WaitStatus: Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(rawStatus: Int32) {
        let signal = rawStatus & 0x7F
        if signal == 0 {
            self = .exited((rawStatus >> 8) & 0xFF)
        } else if signal == 0x7F {
            // Stopped (WIFSTOPPED) — surface as exit 0 since we don't pause.
            self = .exited(0)
        } else {
            self = .signaled(signal)
        }
    }
}

/// One in-flight (or recently-finished) execution of a `RunProfile`. The
/// `terminalView` is created up-front when the task starts so output keeps
/// buffering even when the inspector tab is not visible.
@MainActor
@Observable
final class RunTask: Identifiable {
    let id: UUID
    let profile: RunProfile
    let project: Project
    let startedAt = Date()
    var status: RunTaskStatus = .running
    var exitCode: Int32?

    /// Re-parentable SwiftTerm view. Created once at start; the inspector
    /// view picks it up via `RunTaskTerminalView` representable.
    let terminalView: LocalProcessTerminalView

    let wrapperScript: String
    let resolvedCwd: String
    let resolvedEnvironment: [String: String]
    let outputLogURL: URL
    var terminalOutputTail: String = ""

    private let delegate: RunTaskTerminalDelegate
    nonisolated(unsafe) private var outputCaptureTask: Task<Void, Never>?
    private let onOutputChanged: @MainActor (UUID) -> Void

    init(
        id: UUID = UUID(),
        profile: RunProfile,
        project: Project,
        wrapperScript: String,
        resolvedCwd: String,
        resolvedEnvironment: [String: String],
        outputLogURL: URL,
        onOutputChanged: @escaping @MainActor (UUID) -> Void,
        onTerminated: @escaping @MainActor (UUID, Int32) -> Void
    ) {
        self.id = id
        self.profile = profile
        self.project = project
        self.wrapperScript = wrapperScript
        self.resolvedCwd = resolvedCwd
        self.resolvedEnvironment = resolvedEnvironment
        self.outputLogURL = outputLogURL
        self.onOutputChanged = onOutputChanged

        let tv = LocalProcessTerminalView(frame: .zero)
        Self.applyTheme(to: tv)
        self.terminalView = tv

        let capturedId = id
        self.delegate = RunTaskTerminalDelegate { code in
            onTerminated(capturedId, code)
        }
        tv.processDelegate = delegate
    }

    func start() {
        let envPairs = resolvedEnvironment.map { "\($0.key)=\($0.value)" }
        // Login but *not* interactive: `-i` makes `set -e` + builtins (e.g.
        // `cd`) exit with code 1 and skip the EXIT trap in zsh — a quirk that
        // left users staring at a silent "exit 1" with no diagnostics.
        // `-l` still sources /etc/zprofile and ~/.zprofile, which is where
        // macOS and Homebrew configure PATH. The wrapper script also
        // tolerantly sources ~/.zshrc for users who stash PATH there.
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", wrapperScript],
            environment: envPairs,
            currentDirectory: resolvedCwd
        )
        startOutputCapture()
    }

    func terminate() {
        guard !status.isTerminal else { return }
        terminalView.terminate()
        // Pre-empt the status so the UI updates immediately. The delegate
        // will fire shortly after with the real exit code; we keep the
        // `.stopped` label rather than overwriting it.
        status = .stopped
    }

    private func startOutputCapture() {
        outputCaptureTask?.cancel()
        outputCaptureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                self.refreshOutputTail()
                self.onOutputChanged(self.id)
                if self.status.isTerminal { break }
            }
            self?.refreshOutputTail()
            if let self { self.onOutputChanged(self.id) }
        }
    }

    private func refreshOutputTail() {
        guard let data = try? Data(contentsOf: outputLogURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        terminalOutputTail = String(text.suffix(20_000))
    }

    deinit {
        outputCaptureTask?.cancel()
        try? FileManager.default.removeItem(at: outputLogURL)
    }

    private static func applyTheme(to tv: LocalProcessTerminalView) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tv.nativeBackgroundColor = isDark
            ? NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x18/255.0, alpha: 1)
            : NSColor(red: 0xE8/255.0, green: 0xE5/255.0, blue: 0xDC/255.0, alpha: 1)
        tv.nativeForegroundColor = isDark
            ? NSColor(red: 0xCC/255.0, green: 0xC9/255.0, blue: 0xC0/255.0, alpha: 1)
            : NSColor(red: 0x3C/255.0, green: 0x39/255.0, blue: 0x29/255.0, alpha: 1)
    }
}

private final class RunTaskTerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    nonisolated(unsafe) let onTerminated: (Int32) -> Void

    init(onTerminated: @escaping (Int32) -> Void) {
        self.onTerminated = onTerminated
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTerminated(exitCode ?? -1)
    }
}

extension RunService {
    /// Test seam so unit tests can exercise status decoding without spawning
    /// a real subprocess.
    static func statusFromRawWaitpid(_ raw: Int32) -> RunTaskStatus {
        switch WaitStatus(rawStatus: raw) {
        case .exited(let code):
            return code == 0 ? .succeeded : .failed(code)
        case .signaled(let sig):
            return .signaled(sig)
        }
    }
}

/// Owns running tasks for the whole app. One instance lives on
/// `AppState.runService` so the toolbar, inspector, and dropdown all read
/// the same source of truth.
@MainActor
@Observable
final class RunService {

    private let logger = Logger(subsystem: "com.claudework", category: "RunService")
    var onTasksChanged: (() -> Void)?

    /// Most-recent task first. Includes finished tasks so the inspector
    /// dropdown can show their output until cleared.
    private(set) var tasks: [RunTask] = []

    /// Tasks still alive — drives toolbar stop-button visibility.
    var activeTasks: [RunTask] {
        tasks.filter { !$0.status.isTerminal }
    }

    @discardableResult
    func start(profile: RunProfile, project: Project) -> RunTask {
        // Replace any previous task for the same profile+project so a re-run
        // doesn't accumulate stale terminal sessions in the dropdown. Active
        // tasks (the run button is normally disabled in that case, but be
        // defensive) are terminated first so their subprocess isn't orphaned.
        for existing in tasks where existing.profile.id == profile.id && existing.project.id == project.id {
            if !existing.status.isTerminal {
                existing.terminate()
            }
        }
        tasks.removeAll { $0.profile.id == profile.id && $0.project.id == project.id }

        let cwd = RunTaskExecutor.resolveWorkingDirectory(
            profile.bash.workingDirectory,
            projectPath: project.path
        )
        let preset = profile.bash.environments.first { $0.id == profile.bash.activePresetId }
            ?? profile.bash.environments.first
        let env = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: project.path,
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        let outputLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-run-\(UUID().uuidString).log")
        let script = RunTaskExecutor.buildWrapperScript(
            profile: profile,
            projectPath: project.path,
            outputLogPath: outputLogURL.path
        )

        let task = RunTask(
            profile: profile,
            project: project,
            wrapperScript: script,
            resolvedCwd: cwd,
            resolvedEnvironment: env,
            outputLogURL: outputLogURL,
            onOutputChanged: { [weak self] _ in
                self?.onTasksChanged?()
            },
            onTerminated: { [weak self] id, rawStatus in
                Task { @MainActor in
                    self?.taskTerminated(id: id, rawStatus: rawStatus)
                }
            }
        )
        tasks.insert(task, at: 0)
        task.start()
        onTasksChanged?()
        return task
    }

    func stop(taskId: UUID) {
        tasks.first { $0.id == taskId }?.terminate()
        onTasksChanged?()
    }

    func stopAll() {
        for task in activeTasks { task.terminate() }
        onTasksChanged?()
    }

    func task(id: UUID) -> RunTask? {
        tasks.first { $0.id == id }
    }

    /// Remove a finished task from the list. No-op while running.
    func remove(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status.isTerminal else { return }
        tasks.remove(at: idx)
        onTasksChanged?()
    }

    /// Remove every finished task. Active tasks are left in place.
    func clearFinished() {
        tasks.removeAll { $0.status.isTerminal }
        onTasksChanged?()
    }

    private func taskTerminated(id: UUID, rawStatus: Int32) {
        guard let task = tasks.first(where: { $0.id == id }) else {
            logger.warning("processTerminated for unknown task id=\(id, privacy: .public) raw=\(rawStatus, privacy: .public)")
            return
        }
        let decoded = WaitStatus(rawStatus: rawStatus)
        switch decoded {
        case .exited(let code):
            task.exitCode = code
        case .signaled(let sig):
            task.exitCode = 128 + sig
        }
        // If the user explicitly stopped, preserve `.stopped`. Otherwise pick
        // based on the decoded waitpid status.
        if task.status != .stopped {
            task.status = Self.statusFromRawWaitpid(rawStatus)
        }
        onTasksChanged?()
    }
}
