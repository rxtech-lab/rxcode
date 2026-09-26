import CryptoKit
import Foundation

// MARK: - NotionCredential

/// What RxCode authenticates to Notion with: an OAuth grant from "Connect with
/// Notion", or an internal integration token pasted by hand.
///
/// Stored in the Keychain as JSON. A bare string (how pasted tokens were
/// stored before OAuth) decodes as a manual token.
public struct NotionCredential: Codable, Sendable, Hashable {
    public var accessToken: String
    /// Present for OAuth grants; exchanged through the relay when the access
    /// token is rejected.
    public var refreshToken: String?
    public var workspaceId: String?
    public var workspaceName: String?
    /// HTTP base URL of the relay that made the grant. Refreshes must go back
    /// to it, since only that relay holds the matching client secret.
    public var relayURL: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        workspaceId: String? = nil,
        workspaceName: String? = nil,
        relayURL: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.relayURL = relayURL
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case workspaceId = "workspace_id"
        case workspaceName = "workspace_name"
        case relayURL = "relay_url"
    }

    public var isOAuth: Bool { refreshToken != nil || workspaceId != nil }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a stored credential; a non-JSON value is a pasted token.
    public static func decode(_ data: Data) -> NotionCredential? {
        if let credential = try? JSONDecoder().decode(NotionCredential.self, from: data),
           !credential.accessToken.isEmpty {
            return credential
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("{")
        else { return nil }
        return NotionCredential(accessToken: raw)
    }

    /// The same grant with tokens from a refresh. Notion doesn't repeat the
    /// workspace fields on refresh, so they are kept, as is the relay.
    public func refreshed(with response: NotionCredential) -> NotionCredential {
        NotionCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            workspaceId: response.workspaceId ?? workspaceId,
            workspaceName: response.workspaceName ?? workspaceName,
            relayURL: relayURL
        )
    }
}

// MARK: - NotionOAuthSession

/// One "Connect with Notion" attempt through the relay.
///
/// The app makes a throwaway X25519 key pair and sends only the public key;
/// the relay exchanges Notion's code and returns the token encrypted to it,
/// so the token never appears in plaintext in the callback URL. The nonce ties
/// the callback to this attempt.
public struct NotionOAuthSession: Sendable {
    public static let callbackScheme = "rxcode"
    public static let callbackHost = "notion-callback"
    static let envelopeInfo = Data("rxcode-notion-oauth-v1".utf8)

    public let nonce: String
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        nonce = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
    }

    init(privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: String) {
        self.privateKey = privateKey
        self.nonce = nonce
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// The HTTP base of a relay configured by its WebSocket URL, e.g.
    /// `wss://relay.example.com/ws` → `https://relay.example.com`. A path
    /// prefix in front of `/ws` is kept for relays served under a subpath.
    public static func httpBaseURL(forRelay relayURL: URL) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false
        else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "ws" { segments.removeLast() }
        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The relay page that starts the flow.
    public func startURL(relayBaseURL: URL) -> URL {
        var components = URLComponents(
            url: relayBaseURL.appendingPathComponent("notion/oauth/start"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "pubkey", value: publicKey.base64URLEncoded),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.url!
    }

    /// The credential carried by the relay's `rxcode://notion-callback` URL.
    public func credential(from callback: URL) throws -> NotionCredential {
        guard callback.scheme == Self.callbackScheme, callback.host == Self.callbackHost,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { throw NotionOAuthError.invalidCallback }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("n") == nonce else { throw NotionOAuthError.invalidCallback }
        if let error = value("error") {
            throw error == "access_denied" ? NotionOAuthError.cancelled : NotionOAuthError.denied(error)
        }
        guard let epk = value("epk").flatMap(Data.init(base64URLEncoded:)),
              let iv = value("iv").flatMap(Data.init(base64URLEncoded:)),
              let ciphertext = value("ct").flatMap(Data.init(base64URLEncoded:)),
              ciphertext.count > 16
        else { throw NotionOAuthError.invalidCallback }

        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: epk + publicKey,
                sharedInfo: Self.envelopeInfo,
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            let plaintext = try AES.GCM.open(box, using: key)
            guard let credential = try? JSONDecoder().decode(NotionCredential.self, from: plaintext),
                  !credential.accessToken.isEmpty
            else { throw NotionOAuthError.invalidCallback }
            return credential
        } catch let error as NotionOAuthError {
            throw error
        } catch {
            throw NotionOAuthError.invalidCallback
        }
    }

    /// Encrypts `credential` the way the relay does. Test support only.
    static func seal(_ credential: NotionCredential, to publicKey: Data) throws -> (epk: Data, iv: Data, ciphertext: Data) {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        )
        let epk = ephemeral.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: epk + publicKey,
            sharedInfo: envelopeInfo,
            outputByteCount: 32
        )
        let box = try AES.GCM.seal(credential.encoded(), using: key)
        return (epk, Data(box.nonce), box.ciphertext + box.tag)
    }
}

public enum NotionOAuthError: LocalizedError, Equatable {
    case cancelled
    case denied(String)
    case invalidCallback

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(localized: "Notion sign-in was cancelled.")
        case .denied(let message):
            return String(localized: "Notion sign-in failed: \(message)")
        case .invalidCallback:
            return String(localized: "Notion sign-in returned an unexpected response. Please try again.")
        }
    }
}

// MARK: - base64url

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
