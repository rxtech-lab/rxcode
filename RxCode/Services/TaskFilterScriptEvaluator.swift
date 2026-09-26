#if os(macOS)
import CryptoKit
import Foundation
import os
import RxCodeCore

/// Compiles and runs agent-written Swift view filters (`TaskFilterScript`).
///
/// Like `CustomMenuConditionEvaluator`, the script is wrapped in a harness,
/// compiled with `xcrun swiftc` and cached by a SHA-256 of the full source.
/// Evaluation pipes the board's tasks and stories in as JSON on stdin and reads
/// back the ids the script kept.
actor TaskFilterScriptEvaluator {
    private let logger = Logger(subsystem: "com.rxlab.RxCode", category: "TaskFilterScript")

    /// A filter over a large board is still a tight loop; anything slower is
    /// a runaway script.
    private let evaluationTimeout: TimeInterval = 10

    struct CompileResult: Sendable {
        let success: Bool
        /// Compiler diagnostics, shown in the filter popover on failure.
        let diagnostics: String
    }

    enum Outcome: Sendable, Hashable {
        case selection(TaskFilterScript.Selection)
        case failure(String)
    }

    // MARK: - Public API

    func compile(script: String) async -> CompileResult {
        let source = TaskFilterScript.harness(userScript: script)
        let binaryURL = cachedBinaryURL(forSource: source)
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            return CompileResult(success: true, diagnostics: "")
        }
        do {
            return try await compile(source: source, to: binaryURL)
        } catch {
            return CompileResult(success: false, diagnostics: "Failed to run the Swift compiler: \(error.localizedDescription)")
        }
    }

    /// Runs `script` over `input`, compiling first when the binary isn't cached.
    func evaluate(script: String, input: TaskFilterScript.Input) async -> Outcome {
        let source = TaskFilterScript.harness(userScript: script)
        let binaryURL = cachedBinaryURL(forSource: source)

        if !FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            let result = await compile(script: script)
            guard result.success else {
                return .failure(result.diagnostics.isEmpty ? "The filter didn't compile." : result.diagnostics)
            }
        }

        do {
            let data = try TaskFilterScript.encode(input)
            let output = try await run(binaryURL, stdin: data, timeout: evaluationTimeout)
            guard output.status == 0 else {
                let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message.isEmpty ? "The filter exited with status \(output.status)." : message)
            }
            return .selection(TaskFilterScript.Selection(try TaskFilterScript.decodeOutput(output.stdout)))
        } catch is Timeout {
            return .failure("The filter took longer than \(Int(evaluationTimeout)) seconds.")
        } catch {
            logger.warning("Task filter evaluation failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Compilation

    private func compile(source: String, to binaryURL: URL) async throws -> CompileResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RxCodeTaskFilters", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Not main.swift: that file name rejects `@main`.
        let sourceURL = tempDir.appendingPathComponent("filter.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Compile to a staged path and move it in, so a half-written binary
        // never looks cached.
        let stagedBinary = tempDir.appendingPathComponent("filter.bin")
        let result = try await run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-Onone", "-parse-as-library", sourceURL.path, "-o", stagedBinary.path],
            timeout: 120
        )

        guard FileManager.default.isExecutableFile(atPath: stagedBinary.path) else {
            let diagnostics = Self.userFacingDiagnostics(
                String(data: result.stdout + result.stderr, encoding: .utf8) ?? "",
                sourcePath: sourceURL.path
            )
            return CompileResult(success: false, diagnostics: diagnostics.isEmpty ? "Compilation failed." : diagnostics)
        }

        try? FileManager.default.removeItem(at: binaryURL)
        try FileManager.default.moveItem(at: stagedBinary, to: binaryURL)
        return CompileResult(success: true, diagnostics: "")
    }

    /// Drops the temp directory from compiler paths so diagnostics read
    /// `filter.swift:12:5: error: …`.
    private static func userFacingDiagnostics(_ raw: String, sourcePath: String) -> String {
        raw.replacingOccurrences(of: sourcePath, with: "filter.swift")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cachedBinaryURL(forSource source: String) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RxCode/task-filters", isDirectory: true)
            .appendingPathComponent(hash)
    }

    // MARK: - Process runner

    private struct ProcessOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private struct Timeout: Error {}

    /// Runs `executable` to completion, feeding `stdin`, or throws `Timeout`
    /// after `timeout` seconds. Output is drained concurrently so a large
    /// result can't fill the pipe and stall the child.
    private func run(
        _ executable: URL,
        arguments: [String] = [],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        // Installed before launch so a process that exits instantly still
        // reports it; the stream buffers the signal until it is awaited.
        let (exited, exitContinuation) = AsyncStream<Void>.makeStream()
        proc.terminationHandler = { _ in
            exitContinuation.yield()
            exitContinuation.finish()
        }

        try proc.run()

        let outReader = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errReader = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }
        if let stdin {
            let writer = inPipe.fileHandleForWriting
            Task.detached {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exited {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        guard finished else {
            if proc.isRunning { proc.terminate() }
            throw Timeout()
        }
        return ProcessOutput(
            status: proc.terminationStatus,
            stdout: await outReader.value,
            stderr: await errReader.value
        )
    }
}
#endif
