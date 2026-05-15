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
        }
    }
}

actor ACPInstallerService {

    private let logger = Logger(subsystem: "com.claudework", category: "ACPInstaller")
    private let session: URLSession = .shared

    static let shared = ACPInstallerService()

    /// Returns the install root: `~/Library/Application Support/RxCode/acp-binaries/`.
    static func installRoot() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("RxCode/acp-binaries", isDirectory: true)
    }

    /// Downloads + extracts `bin`, returning the absolute path of the resolved executable.
    func install(_ bin: ACPBinaryDist, registryId: String, version: String) async throws -> String {
        let installDir = Self.installRoot()
            .appendingPathComponent(registryId, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let fm = FileManager.default

        // Resolve cmd to an absolute path early so we can short-circuit if already installed.
        let resolvedCmdPath = resolveCmdPath(cmd: bin.cmd, installDir: installDir)
        if fm.isExecutableFile(atPath: resolvedCmdPath) {
            logger.info("[ACPInstaller] reusing existing install at \(resolvedCmdPath, privacy: .public)")
            return resolvedCmdPath
        }

        // Fresh install: clear stale partials, recreate dir.
        try? fm.removeItem(at: installDir)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        guard let archiveURL = URL(string: bin.archive) else {
            throw ACPInstallError.unsupportedArchive(bin.archive)
        }

        logger.info("[ACPInstaller] downloading \(bin.archive, privacy: .public)")
        let downloaded: URL
        do {
            let (tempURL, _) = try await session.download(from: archiveURL)
            downloaded = tempURL
        } catch {
            throw ACPInstallError.downloadFailed(underlying: error)
        }
        defer { try? fm.removeItem(at: downloaded) }

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
        let dir = Self.installRoot().appendingPathComponent(registryId, isDirectory: true)
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
