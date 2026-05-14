import Foundation
import RxCodeCore
import os
import Security

actor GitHubService {

    static let oauthClientId = "Ov23liaj3hlJoMGsNZTW"
    private let clientId = oauthClientId
    private let logger = Logger(subsystem: "com.claudework", category: "GitHubService")
    private let sshKeyManager = SSHKeyManager()

    private(set) var accessToken: String?
    private(set) var currentUser: GitHubUser?

    // MARK: - Errors

    enum GitHubError: LocalizedError {
        case noAccessToken
        case deviceCodeExpired
        case accessDenied
        case networkError(String)
        case apiError(Int, String)
        case decodingError(String)
        case cloneFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAccessToken:
                return "Not authenticated. Please sign in with GitHub."
            case .deviceCodeExpired:
                return "The device code has expired. Please restart the login process."
            case .accessDenied:
                return "Access was denied. Please try again and authorize the app."
            case .networkError(let detail):
                return "Network error: \(detail)"
            case .apiError(let code, let message):
                return "GitHub API error (\(code)): \(message)"
            case .decodingError(let detail):
                return "Failed to decode response: \(detail)"
            case .cloneFailed(let detail):
                return "Git clone failed: \(detail)"
            case .invalidResponse:
                return "Received an invalid response from GitHub."
            }
        }
    }

    // MARK: - Keychain Constants

    private let keychainService = "com.claudework.github"
    private let keychainAccount = "access_token"

    // MARK: - Device Flow OAuth

    /// Start the GitHub Device Flow by requesting a device code.
    func startDeviceFlow() async throws -> DeviceCodeResponse {
        let url = URL(string: "https://github.com/login/device/code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientId,
            "scope": "repo,read:org"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw GitHubError.apiError(statusCode, body)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    /// Poll GitHub for an access token after the user has entered their device code.
    ///
    /// - Parameters:
    ///   - deviceCode: The device code from `startDeviceFlow()`.
    ///   - interval: The minimum polling interval in seconds.
    /// - Returns: The access token string.
    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        var currentInterval = interval
        let maxAttempts = 60 // Max 60 attempts (~5 minutes)
        var attempts = 0

        let url = URL(string: "https://github.com/login/oauth/access_token")!

        while attempts < maxAttempts {
            attempts += 1
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "client_id": clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
                throw GitHubError.apiError(statusCode, responseBody)
            }

            // Try to decode as a successful token response first.
            if let tokenResponse = try? JSONDecoder().decode(AccessTokenResponse.self, from: data),
               !tokenResponse.accessToken.isEmpty {
                self.accessToken = tokenResponse.accessToken
                try saveToken(tokenResponse.accessToken)
                return tokenResponse.accessToken
            }

            // Otherwise, check the error field for polling status.
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let errorCode = json["error"] as? String else {
                throw GitHubError.invalidResponse
            }

            switch errorCode {
            case "authorization_pending":
                // User hasn't authorized yet; keep polling.
                continue
            case "slow_down":
                // Increase interval by 5 seconds per spec.
                currentInterval += 5
                continue
            case "expired_token":
                throw GitHubError.deviceCodeExpired
            case "access_denied":
                throw GitHubError.accessDenied
            default:
                let description = json["error_description"] as? String ?? errorCode
                throw GitHubError.apiError(0, description)
            }
        }

        throw GitHubError.deviceCodeExpired
    }

    // MARK: - Token Management (Keychain)

    func saveToken(_ token: String) throws {
        guard let tokenData = token.data(using: .utf8) else { return }
        do {
            try KeychainHelper.save(tokenData, service: keychainService, account: keychainAccount)
        } catch {
            logger.error("Keychain save failed: \(error)")
            throw GitHubError.networkError("Failed to save token to Keychain")
        }
        self.accessToken = token
        logger.info("GitHub token saved to Keychain.")
    }

    func loadToken() -> String? {
        guard let token = KeychainHelper.readString(service: keychainService, account: keychainAccount) else {
            return nil
        }
        self.accessToken = token
        return token
    }

    func deleteToken() throws {
        do {
            try KeychainHelper.delete(service: keychainService, account: keychainAccount)
        } catch {
            logger.error("Keychain delete failed: \(error)")
            throw GitHubError.networkError("Failed to delete token from Keychain")
        }
        self.accessToken = nil
        self.currentUser = nil
        logger.info("GitHub token deleted from Keychain.")
    }

    // MARK: - API Calls

    func fetchUser() async throws -> GitHubUser {
        let user: GitHubUser = try await apiRequest(path: "/user")
        self.currentUser = user
        return user
    }

    func fetchRepos() async throws -> [GitHubRepo] {
        // Fetch all repos with pagination (including organizations)
        var allRepos: [GitHubRepo] = []
        var page = 1
        while true {
            let repos: [GitHubRepo] = try await apiRequest(
                path: "/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member&page=\(page)"
            )
            allRepos.append(contentsOf: repos)
            if repos.count < 100 { break }
            page += 1
        }
        return allRepos
    }

    // MARK: - SSH Setup

    /// Generate or reuse an SSH key and return the public key contents.
    func setupSSH() async throws -> String {
        let exists = await sshKeyManager.keyExists
        if !exists {
            try await sshKeyManager.generateKey()
        }
        try await sshKeyManager.configureSSHConfig()
        try await sshKeyManager.addToKnownHosts()
        return try await sshKeyManager.readPublicKey()
    }

    /// Register the given public key with the authenticated GitHub user.
    func registerSSHKey(_ publicKey: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "title": "RxCode (\(Host.current().localizedName ?? "Mac"))",
                "key": publicKey
            ]
        )

        let _: SSHKeyResponse = try await apiRequest(
            path: "/user/keys",
            method: "POST",
            body: body
        )

        logger.info("SSH key registered with GitHub.")
    }

    // MARK: - Clone

    func cloneRepo(_ repo: GitHubRepo, to path: String) async throws {
        guard let token = accessToken else {
            throw GitHubError.noAccessToken
        }

        // HTTPS clone with token — no SSH setup required
        let cloneURL = "https://x-access-token:\(token)@github.com/\(repo.fullName).git"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", cloneURL, path]
        process.environment = ProcessInfo.processInfo.environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Wait for process exit asynchronously instead of blocking the actor
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw GitHubError.cloneFailed(stderr)
        }

        logger.info("Cloned \(repo.fullName, privacy: .public) to \(path, privacy: .public)")
    }

    // MARK: - Private Helpers

    private func apiRequest<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        guard let token = accessToken else {
            throw GitHubError.noAccessToken
        }

        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubError.networkError("Invalid URL: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            throw GitHubError.apiError(httpResponse.statusCode, responseBody)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }
}

// MARK: - Internal Response Types

/// Minimal response type for POST /user/keys.
private struct SSHKeyResponse: Decodable {
    let id: Int
    let key: String

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
    }

    enum CodingKeys: CodingKey { case id, key }
}
