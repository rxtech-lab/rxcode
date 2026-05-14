import Foundation

// MARK: - GitHub User

public struct GitHubUser: Codable, Sendable {
    public let login: String
    public let name: String?
    public let avatarUrl: String

    public init(login: String, name: String?, avatarUrl: String) {
        self.login = login
        self.name = name
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case login
        case name
        case avatarUrl = "avatar_url"
    }
}

// MARK: - GitHub Repo

public struct GitHubRepo: Identifiable, Codable, Sendable {
    public let id: Int
    public let fullName: String
    public let name: String
    public let owner: Owner
    public let isPrivate: Bool
    public let htmlUrl: String

    public struct Owner: Codable, Sendable {
        public let login: String

        public init(login: String) {
            self.login = login
        }
    }

    public init(id: Int, fullName: String, name: String, owner: Owner, isPrivate: Bool, htmlUrl: String) {
        self.id = id
        self.fullName = fullName
        self.name = name
        self.owner = owner
        self.isPrivate = isPrivate
        self.htmlUrl = htmlUrl
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case name
        case owner
        case isPrivate = "private"
        case htmlUrl = "html_url"
    }
}

// MARK: - Device Flow: Device Code Response

public struct DeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int

    public init(deviceCode: String, userCode: String, verificationUri: String, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.expiresIn = expiresIn
        self.interval = interval
    }

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

// MARK: - Device Flow: Access Token Response

public struct AccessTokenResponse: Codable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let scope: String?

    public init(accessToken: String, tokenType: String, scope: String?) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}
