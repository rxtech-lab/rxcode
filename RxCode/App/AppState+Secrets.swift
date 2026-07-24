#if os(macOS)
import CryptoKit
import Foundation
import RxCodeCore

/// High-level secrets intents: orchestrate the passkey-derived KEK
/// (`secretsKeyVault`), the crypto (`SecretsCrypto`/`SecretsFlows`), and the
/// network (`secrets`). Views call these and never touch crypto directly.
extension AppState {

    // MARK: - Enrollment

    /// Refreshes `secretsEnrolled` from the backend. Leaves it `nil` (unknown)
    /// on transport errors so the UI can distinguish "not enrolled" from "can't
    /// tell yet".
    func refreshSecretsEnrollment() async {
        guard isSignedIn else { secretsEnrolled = nil; return }
        do {
            let key = try await secrets.getUserKey()
            secretsEnrolled = key.enrolled
        } catch {
            secretsEnrolled = nil
        }
    }

    /// Generates the user's keypair, wraps the private key under the
    /// passkey-derived KEK, and publishes it. Prompts for the passkey.
    func enrollSecrets() async throws {
        let kek = try await secretsKeyVault.kek()
        let result = try await SecretsFlows.enroll(kek: kek)
        try await secrets.putUserKey(result.body)
        secretsEnrolled = true
    }

    // MARK: - Status (batch)

    /// Refreshes `secretsStatusByRepo` for every open project's GitHub repo so
    /// the sidebar can show "Download Secret" only where secrets exist. Leaves
    /// the previous cache untouched on transient errors.
    func refreshSecretsStatuses() async {
        guard isSignedIn else { secretsStatusByRepo = [:]; return }
        let repos = Array(Set(projects.compactMap(\.gitHubRepo)))
        guard !repos.isEmpty else { secretsStatusByRepo = [:]; return }
        do {
            let statuses = try await secrets.statuses(forRepos: repos)
            secretsStatusByRepo = Dictionary(
                statuses.map { ($0.fullName.lowercased(), $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            // Keep the prior cache; a failed poll shouldn't hide existing buttons.
        }
    }

    /// Whether the project's linked repo has secrets configured (managed).
    func projectHasSecrets(_ project: Project) -> Bool {
        guard let repo = project.gitHubRepo else { return false }
        return secretsStatusByRepo[repo.lowercased()]?.isManaged ?? false
    }

    // MARK: - Repository management

    /// Ensures the repo is registered for secrets management, returning its
    /// internal secrets id (adds it on first use).
    func ensureSecretsRepoManaged(_ repo: SecretsManagedRepo) async throws -> String {
        if let id = repo.secretsRepoId { return id }
        let result = try await secrets.addRepository(
            AddSecretsRepoBody(
                installationId: repo.installationId,
                repositoryId: repo.id,
                repositoryFullName: repo.fullName
            )
        )
        return result.id
    }

    // MARK: - Environments

    /// Creates a new environment with a fresh DEK wrapped under the owner's KEK.
    func createSecretEnvironment(repo: String, name: String) async throws {
        let kek = try await secretsKeyVault.kek()
        let owner = try SecretsFlows.buildOwnerEnvironmentKey(kek: kek)
        _ = try await secrets.createEnvironment(
            repo: repo,
            body: CreateEnvironmentBody(name: name, ownerKey: owner.body)
        )
    }

    // MARK: - File encryption / decryption

    /// Resolves an environment's wrapped DEK into a usable key, unwrapping the
    /// user's private key first when the environment was shared via HPKE.
    private func resolveDEK(for envKey: SecretsEnvironmentKey) async throws -> SymmetricKey {
        let kek = try await secretsKeyVault.kek()
        if envKey.wrapMode == "hpke" {
            let userKey = try await secrets.getUserKey()
            let priv = try SecretsFlows.unwrapUserPrivateKey(userKey, kek: kek)
            return try SecretsFlows.unwrapDEK(envKey: envKey, kek: kek, userPrivateKey: priv)
        }
        return try SecretsFlows.unwrapDEK(envKey: envKey, kek: kek, userPrivateKey: nil)
    }

    /// Builds an upload body by encrypting `content` under the environment DEK.
    func encryptSecretFile(
        forEnvironmentKey envKey: SecretsEnvironmentKey,
        filename: String,
        content: String
    ) async throws -> UpsertFileBody {
        let dek = try await resolveDEK(for: envKey)
        let enc = try SecretsCrypto.encryptFile(plaintext: content, dek: dek)
        return UpsertFileBody(filename: filename, ciphertext: enc.ciphertext, iv: enc.iv, size: enc.size)
    }

    /// Decrypts a single file given its environment key + ciphertext.
    func decryptSecretFile(
        envKey: SecretsEnvironmentKey,
        ciphertext: String,
        iv: String
    ) async throws -> String {
        let dek = try await resolveDEK(for: envKey)
        return try SecretsCrypto.decryptFile(ciphertextB64: ciphertext, ivB64: iv, dek: dek)
    }

    /// Decrypts every file in a bundle to plaintext.
    func decryptSecretBundle(
        _ bundle: SecretsBundle
    ) async throws -> [(filename: String, content: String)] {
        let dek = try await resolveDEK(for: bundle.environmentKey)
        return try bundle.files.map { file in
            (file.filename, try SecretsCrypto.decryptFile(ciphertextB64: file.ciphertext, ivB64: file.iv, dek: dek))
        }
    }

    // MARK: - Download

    /// Downloads + decrypts an environment and writes its files into
    /// `directory`. Returns the filenames written (skips existing files unless
    /// `overwrite`). Prompts for the passkey.
    @discardableResult
    func downloadSecrets(
        repo: String,
        env: String,
        to directory: URL,
        overwrite: Bool
    ) async throws -> [String] {
        let bundle = try await secrets.bundle(repo: repo, env: env)
        let files = try await decryptSecretBundle(bundle)
        return try writeDecryptedSecrets(files, to: directory, overwrite: overwrite)
    }

    /// Writes already-decrypted `(filename, content)` pairs into `directory`,
    /// skipping existing files unless `overwrite`. Returns filenames written.
    @discardableResult
    func writeDecryptedSecrets(
        _ files: [(filename: String, content: String)],
        to directory: URL,
        overwrite: Bool
    ) throws -> [String] {
        var written: [String] = []
        for file in files {
            // `filename` is a repo-relative path (e.g. "frontend/.env") that may
            // arrive from an untrusted cloud/peer source, so resolve it through
            // the shared safe-destination contract — the same one conflict
            // detection uses — and skip anything invalid or escaping `directory`.
            guard let dest = SecretsFilePath.safeDestination(for: file.filename, in: directory) else { continue }
            if !overwrite, FileManager.default.fileExists(atPath: dest.url.path) { continue }
            let parent = dest.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(file.content.utf8).write(to: dest.url, options: .atomic)
            written.append(dest.name)
        }
        return written
    }
}
#endif
