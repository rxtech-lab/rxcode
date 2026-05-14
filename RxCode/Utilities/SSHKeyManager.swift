import Foundation
import os

/// Manages an ed25519 SSH key dedicated to RxCode for GitHub access.
///
/// The key pair lives at `~/.ssh/claudework_ed25519` (private) and
/// `~/.ssh/claudework_ed25519.pub` (public). All shell operations use
/// `Foundation.Process`.
actor SSHKeyManager {

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "SSHKeyManager"
    )

    private let sshDirectory: String
    private let keyPath: String
    private let publicKeyPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.sshDirectory = "\(home)/.ssh"
        self.keyPath = "\(home)/.ssh/claudework_ed25519"
        self.publicKeyPath = "\(home)/.ssh/claudework_ed25519.pub"
    }

    // MARK: - Public API

    /// Whether the private key file already exists on disk.
    var keyExists: Bool {
        FileManager.default.fileExists(atPath: keyPath)
    }

    /// Generate a new ed25519 SSH key pair with an empty passphrase.
    ///
    /// - Throws: `SSHKeyError.generationFailed` if `ssh-keygen` exits non-zero.
    func generateKey() async throws {
        // Ensure ~/.ssh directory exists with correct permissions.
        try ensureSSHDirectory()

        let result = try await run(
            "/usr/bin/ssh-keygen",
            arguments: ["-t", "ed25519", "-f", keyPath, "-N", "", "-C", "claudework"]
        )

        guard result.exitCode == 0 else {
            let stderr = result.stderr
            logger.error("ssh-keygen failed (\(result.exitCode)): \(stderr, privacy: .public)")
            throw SSHKeyError.generationFailed(stderr)
        }

        logger.info("Generated SSH key at \(self.keyPath, privacy: .public)")
    }

    /// Read the contents of the public key file.
    ///
    /// - Returns: The full public key string (trimmed of trailing whitespace).
    /// - Throws: `SSHKeyError.publicKeyNotFound` if the `.pub` file does not exist.
    func readPublicKey() throws -> String {
        guard FileManager.default.fileExists(atPath: publicKeyPath) else {
            throw SSHKeyError.publicKeyNotFound
        }

        let content = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Add a `Host github.com` entry to `~/.ssh/config` that points at the
    /// RxCode key, but only if such an entry is not already present.
    func configureSSHConfig() async throws {
        let configPath = "\(sshDirectory)/config"

        // Read existing config (or start empty).
        var config = ""
        if FileManager.default.fileExists(atPath: configPath) {
            config = try String(contentsOfFile: configPath, encoding: .utf8)
        }

        // Bail out if the key is already referenced.
        if config.contains("claudework_ed25519") {
            logger.info("SSH config already contains claudework_ed25519 entry, skipping.")
            return
        }

        let entry = """

        # RxCode — GitHub access
        Host github.com-claudework
            HostName github.com
            User git
            IdentityFile \(keyPath)
            IdentitiesOnly yes

        """

        try ensureSSHDirectory()

        // Append the entry.
        if let data = entry.data(using: .utf8) {
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: configPath) {
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: configPath))
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: configPath, contents: data)
                // ssh config should be owner-read/write only.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: configPath
                )
            }
        }

        logger.info("Added RxCode SSH config entry.")
    }

    /// Run `ssh-keyscan github.com` and append the result to `~/.ssh/known_hosts`.
    func addToKnownHosts() async throws {
        let knownHostsPath = "\(sshDirectory)/known_hosts"

        // Check if github.com is already in known_hosts.
        if FileManager.default.fileExists(atPath: knownHostsPath) {
            let existing = try String(contentsOfFile: knownHostsPath, encoding: .utf8)
            if existing.contains("github.com") {
                logger.info("github.com already in known_hosts, skipping.")
                return
            }
        }

        let result = try await run(
            "/usr/bin/ssh-keyscan",
            arguments: ["-t", "ed25519,rsa", "github.com"]
        )

        guard result.exitCode == 0, !result.stdout.isEmpty else {
            let stderr = result.stderr
            logger.error("ssh-keyscan failed (\(result.exitCode)): \(stderr, privacy: .public)")
            throw SSHKeyError.keyscanFailed(stderr)
        }

        try ensureSSHDirectory()

        let data = Data(result.stdout.utf8)
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: knownHostsPath) {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: knownHostsPath))
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: knownHostsPath, contents: data)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: knownHostsPath
            )
        }

        logger.info("Added github.com to known_hosts.")
    }

    // MARK: - Errors

    enum SSHKeyError: LocalizedError {
        case generationFailed(String)
        case publicKeyNotFound
        case keyscanFailed(String)
        case directoryCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .generationFailed(let detail):
                return "SSH key generation failed: \(detail)"
            case .publicKeyNotFound:
                return "Public key file not found. Generate a key first."
            case .keyscanFailed(let detail):
                return "ssh-keyscan failed: \(detail)"
            case .directoryCreationFailed(let detail):
                return "Failed to create .ssh directory: \(detail)"
            }
        }
    }

    // MARK: - Private Helpers

    /// Ensure `~/.ssh` exists with mode 0700.
    private func ensureSSHDirectory() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sshDirectory, isDirectory: &isDir), isDir.boolValue {
            return
        }

        do {
            try FileManager.default.createDirectory(
                atPath: sshDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SSHKeyError.directoryCreationFailed(error.localizedDescription)
        }
    }

    /// Run an executable and capture stdout, stderr, and the exit code.
    private struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func run(
        _ executablePath: String,
        arguments: [String] = []
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let result = ProcessResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
