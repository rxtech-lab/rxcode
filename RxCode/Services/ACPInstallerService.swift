import Foundation
import RxCodeCore
import os

// MARK: - ACPInstallerService
//
// Downloads and extracts an ACP agent's binary distribution into
// `~/Library/Application Support/RxCode/acp-binaries/<id>/<version>/`,
// then returns the absolute path of the executable named by `bin.cmd`.
//
// Supports `.zip`, `.tar.gz`, and `.tgz` archives. The macOS quarantine
// xattr is stripped after extraction so Gatekeeper doesn't block first
// launch.

enum ACPInstallError: LocalizedError {
    case unsupportedArchive(String)
    case downloadFailed(underlying: Error)
    case extractFailed(stderr: String, exitCode: Int32)
    case cmdMissing(path: String)
    case noCompatibleDistribution
    case invalidPackageVersion(package: String, version: String)
    case historicalBinaryUnavailable(version: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive(let url):
            return "Unsupported archive format: \(url)"
        case .downloadFailed(let underlying):
            return "Download failed: \(underlying.localizedDescription)"
        case .extractFailed(let stderr, let exitCode):
            return "Extraction failed (exit \(exitCode)): \(stderr)"
        case .cmdMissing(let path):
            return "Executable not found at \(path) after extraction"
        case .noCompatibleDistribution:
            return "No compatible distribution for this platform."
        case .invalidPackageVersion(let package, let version):
            return "Cannot pin \(package) to version \(version)."
        case .historicalBinaryUnavailable(let version):
            return "Version \(version) is unavailable for this binary-only client. The ACP registry provides a download for its current release only."
        }
    }
}

actor ACPInstallerService {

    private let logger = Logger(subsystem: "com.claudework", category: "ACPInstaller")
    private let sessionConfiguration: URLSessionConfiguration
    private let installRootURL: URL

    struct Progress: Sendable, Equatable {
        enum Phase: Sendable {
            case downloading, extracting, preparing
        }

        var phase: Phase
        var downloadedBytes: Int64 = 0
        var expectedBytes: Int64?
        var bytesPerSecond: Double?

        var fraction: Double? {
            guard phase == .downloading, let expectedBytes, expectedBytes > 0 else { return nil }
            return min(max(Double(downloadedBytes) / Double(expectedBytes), 0), 1)
        }
    }

    static let shared = ACPInstallerService()

    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        installRootURL: URL? = nil
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.installRootURL = installRootURL ?? Self.installRoot()
    }

    /// Returns the install root: `~/Library/Application Support/RxCode/acp-binaries/`.
    static func installRoot() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("RxCode/acp-binaries", isDirectory: true)
    }

    /// Downloads + extracts `bin`, returning the absolute path of the resolved executable.
    func install(
        _ bin: ACPBinaryDist, registryId: String, version: String, displayName: String? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> String {
        let installDir = installRootURL
            .appendingPathComponent(registryId, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let fm = FileManager.default

        // Resolve cmd to an absolute path early so we can short-circuit if already installed.
        let resolvedCmdPath = resolveCmdPath(cmd: bin.cmd, installDir: installDir)
        if fm.isExecutableFile(atPath: resolvedCmdPath) {
            logger.info("[ACPInstaller] reusing existing install at \(resolvedCmdPath, privacy: .public)")
            return resolvedCmdPath
        }

        // A second request for the same agent and version waits for the
        // first: both would clear and extract into the same folder.
        let key = "\(registryId)/\(version)"
        if let running = inFlight[key] { return try await running.value }

        let task = Task {
            try await DownloadCenter.track("\(displayName ?? registryId) \(version)", kind: .acpAgent) { item in
                let reporting: @Sendable (Progress) -> Void = { update in
                    switch update.phase {
                    case .downloading:
                        if update.downloadedBytes > 0 || (update.expectedBytes ?? 0) > 0 {
                            DownloadCenter.update(
                                item,
                                phase: .downloading,
                                receivedBytes: update.downloadedBytes,
                                totalBytes: update.expectedBytes,
                                transferredBytes: update.downloadedBytes
                            )
                        } else {
                            DownloadCenter.update(item, phase: .downloading)
                        }
                    case .extracting, .preparing:
                        DownloadCenter.update(item, phase: .installing)
                    }
                    progress?(update)
                }
                do {
                    return try await self.performInstall(
                        bin, installDir: installDir, resolvedCmdPath: resolvedCmdPath, progress: reporting
                    )
                } catch {
                    // Leave nothing half-extracted behind a failed or cancelled install.
                    try? FileManager.default.removeItem(at: installDir)
                    throw error
                }
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private var inFlight: [String: Task<String, Error>] = [:]

    private func performInstall(
        _ bin: ACPBinaryDist, installDir: URL, resolvedCmdPath: String,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        let fm = FileManager.default
        // Fresh install: clear stale partials, recreate dir.
        try? fm.removeItem(at: installDir)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        guard let archiveURL = URL(string: bin.archive) else {
            throw ACPInstallError.unsupportedArchive(bin.archive)
        }

        logger.info("[ACPInstaller] downloading \(bin.archive, privacy: .public)")
        let downloaded: URL
        do {
            progress?(Progress(phase: .downloading))
            let downloader = ACPArchiveDownloader(configuration: sessionConfiguration, progress: progress)
            let (tempURL, response) = try await downloader.download(from: archiveURL)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                try? fm.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }
            downloaded = tempURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ACPInstallError.downloadFailed(underlying: error)
        }
        defer { try? fm.removeItem(at: downloaded) }
        try Task.checkCancellation()

        progress?(Progress(phase: .extracting))
        try extract(archive: downloaded, originalURL: archiveURL, into: installDir)

        // chmod +x and strip quarantine.
        if fm.isExecutableFile(atPath: resolvedCmdPath) == false {
            // File may exist without exec bit — try to chmod.
            if fm.fileExists(atPath: resolvedCmdPath) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedCmdPath)
            } else {
                throw ACPInstallError.cmdMissing(path: resolvedCmdPath)
            }
        } else {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedCmdPath)
        }
        stripQuarantine(at: installDir)

        return resolvedCmdPath
    }

    /// Removes the install directory tree for the given registry id.
    /// No-op if the directory does not exist.
    func uninstall(registryId: String) {
        let dir = installRootURL.appendingPathComponent(registryId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Returns true if `path` is under the install root (used to decide
    /// whether to clean up on remove).
    nonisolated static func isManaged(path: String) -> Bool {
        let root = installRoot().standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.hasPrefix(root + "/")
    }

    // MARK: - Helpers

    private func resolveCmdPath(cmd: String, installDir: URL) -> String {
        // Strip a leading "./" if present so we can append cleanly.
        var rel = cmd
        if rel.hasPrefix("./") { rel.removeFirst(2) }
        return installDir.appendingPathComponent(rel).path
    }

    private func extract(archive: URL, originalURL: URL, into dir: URL) throws {
        let lower = originalURL.lastPathComponent.lowercased()
        let process = Process()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        if lower.hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", archive.path, "-d", dir.path]
        } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", dir.path]
        } else if lower.hasSuffix(".tar") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", dir.path]
        } else {
            throw ACPInstallError.unsupportedArchive(originalURL.absoluteString)
        }

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw ACPInstallError.extractFailed(stderr: stderr, exitCode: process.terminationStatus)
        }
    }

    private func stripQuarantine(at dir: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", dir.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.warning("[ACPInstaller] failed to strip quarantine: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Runs an ACP binary archive download on its own `URLSession` so
/// `URLSessionDownloadDelegate` byte-progress callbacks are delivered.
/// `URLSession.download(from:delegate:)` only accepts a `URLSessionTaskDelegate`
/// and never invokes `urlSession(_:downloadTask:didWriteData:...)`.
private nonisolated final class ACPArchiveDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let progress: (@Sendable (ACPInstallerService.Progress) -> Void)?
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var destinationURL: URL?
    private var response: URLResponse?
    private var transferError: Error?
    private var startedAt = Date()
    private var lastReportAt = Date.distantPast
    private var lastReportedBytes: Int64 = -1
    private var lastWrittenBytes: Int64 = 0
    private var lastExpectedBytes: Int64?
    private var speedSamples: [(time: Date, bytes: Int64)] = []

    /// Throttle delegate bursts while staying well below `DownloadCenter.byteUpdateInterval`
    /// so UI progress and throughput update smoothly without skipping windows.
    static let reportInterval: TimeInterval = 0.2

    init(
        configuration: URLSessionConfiguration,
        progress: (@Sendable (ACPInstallerService.Progress) -> Void)?
    ) {
        self.configuration = configuration
        self.progress = progress
        super.init()
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.startedAt = Date()
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    let task = session.downloadTask(with: url)
                    self.downloadTask = task
                    task.resume()
                    if Task.isCancelled {
                        task.cancel()
                    }
                }
            }
        } onCancel: {
            lock.withLock { downloadTask }?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        let expected: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let update: ACPInstallerService.Progress? = lock.withLock {
            let learnedExpected = lastExpectedBytes == nil && expected != nil
            lastWrittenBytes = totalBytesWritten
            if let expected { lastExpectedBytes = expected }

            let effectiveExpected = lastExpectedBytes
            let reachedTotal = effectiveExpected.map { totalBytesWritten >= $0 } ?? false
            let isFirstReport = lastReportedBytes < 0
            let elapsedSinceReport = now.timeIntervalSince(lastReportAt)
            guard isFirstReport || learnedExpected || reachedTotal || elapsedSinceReport >= Self.reportInterval else {
                return nil
            }

            let speed = recordSampleAndComputeSpeed(bytes: totalBytesWritten, at: now, isComplete: reachedTotal)
            lastReportAt = now
            lastReportedBytes = totalBytesWritten
            return ACPInstallerService.Progress(
                phase: .downloading,
                downloadedBytes: totalBytesWritten,
                expectedBytes: effectiveExpected,
                bytesPerSecond: speed
            )
        }
        if let update {
            progress?(update)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let response = downloadTask.response
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock {
                self.response = response
                self.transferError = URLError(.badServerResponse)
            }
            return
        }
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-acp-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            lock.withLock {
                self.response = response
                self.destinationURL = tempFile
            }
        } catch {
            lock.withLock {
                self.response = response
                self.transferError = error
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let result: (
            continuation: CheckedContinuation<(URL, URLResponse), Error>?,
            finalProgress: ACPInstallerService.Progress?,
            destinationURL: URL?,
            response: URLResponse?,
            error: Error?
        ) = lock.withLock {
            defer {
                self.continuation = nil
                self.session = nil
                self.downloadTask = nil
            }
            let effectiveError = transferError ?? error
            var finalProgress: ACPInstallerService.Progress?
            if effectiveError == nil, lastWrittenBytes > 0, lastReportedBytes != lastWrittenBytes {
                let now = Date()
                let speed = recordSampleAndComputeSpeed(bytes: lastWrittenBytes, at: now, isComplete: true)
                lastReportedBytes = lastWrittenBytes
                finalProgress = ACPInstallerService.Progress(
                    phase: .downloading,
                    downloadedBytes: lastWrittenBytes,
                    expectedBytes: lastExpectedBytes,
                    bytesPerSecond: speed
                )
            }
            return (continuation, finalProgress, destinationURL, response ?? task.response, effectiveError)
        }

        if let finalProgress = result.finalProgress {
            progress?(finalProgress)
        }

        if let error = result.error {
            if let destinationURL = result.destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                result.continuation?.resume(throwing: CancellationError())
            } else {
                result.continuation?.resume(throwing: error)
            }
            return
        }

        guard let destinationURL = result.destinationURL, let response = result.response else {
            result.continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }
        result.continuation?.resume(returning: (destinationURL, response))
    }

    /// Must be called while holding `lock`.
    private func recordSampleAndComputeSpeed(bytes: Int64, at now: Date, isComplete: Bool) -> Double? {
        if let last = speedSamples.last, bytes < last.bytes {
            speedSamples = []
        }
        speedSamples.append((now, bytes))
        while speedSamples.count > 2, now.timeIntervalSince(speedSamples[1].time) > 5 {
            speedSamples.removeFirst()
        }
        if speedSamples.count >= 2, let first = speedSamples.first, let last = speedSamples.last {
            let elapsed = last.time.timeIntervalSince(first.time)
            if elapsed > 0 {
                return Double(last.bytes - first.bytes) / elapsed
            }
        }
        if isComplete, bytes > 0 {
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed > 0 {
                return Double(bytes) / elapsed
            }
        }
        return nil
    }
}
