#if os(macOS)
import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os
import RxCodeCore

/// Runs a passkey assertion **purely to unlock the WebAuthn PRF extension**, so
/// we can derive the secrets KEK from the user's existing `rxlab.app` passkey.
/// This is the piece `RxAuthSwift` does not provide — it never sets the `prf`
/// extension. The assertion's signature is not verified by anyone; the only
/// thing we want back is the PRF output bytes.
///
/// Mirrors the delegate/anchor structure of RxAuthSwift's
/// `MacOSPasskeyAuthenticator`.
@MainActor
final class SecretsPasskeyAuthenticator: NSObject {

    enum PasskeyError: LocalizedError {
        case cancelled
        case prfUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Passkey authentication was cancelled."
            case .prfUnavailable:
                return "This passkey can't unlock secrets — it doesn't support the PRF extension. Use the passkey you enrolled with."
            case .failed(let detail):
                return "Passkey authentication failed: \(detail)"
            }
        }
    }

    private var continuation: CheckedContinuation<Data, Error>?
    private var retainedSelf: SecretsPasskeyAuthenticator?
    private let logger = Logger(subsystem: "com.claudework", category: "SecretsPasskey")

    /// Performs a discoverable assertion with the PRF extension evaluating
    /// `salt`, and returns the 32-byte PRF output.
    func evaluatePRF(
        salt: Data = SecretsCrypto.prfSalt,
        relyingPartyIdentifier: String = SecretsCrypto.webAuthnRPID
    ) async throws -> Data {
        var challengeBytes = Data(count: 32)
        challengeBytes.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        let challenge = challengeBytes

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.retainedSelf = self

            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.prf = .inputValues(
                ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues(saltInput1: salt)
            )

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func complete(with result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.retainedSelf = nil
        continuation.resume(with: result)
    }
}

extension SecretsPasskeyAuthenticator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            complete(with: .failure(PasskeyError.failed("Unexpected passkey credential")))
            return
        }
        guard let prf = credential.prf?.first else {
            complete(with: .failure(PasskeyError.prfUnavailable))
            return
        }
        // PRF output is exposed as a SymmetricKey; we need its raw bytes for HKDF.
        let prfBytes = prf.withUnsafeBytes { Data($0) }
        complete(with: .success(prfBytes))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain,
           ASAuthorizationError.Code(rawValue: nsError.code) == .canceled {
            complete(with: .failure(PasskeyError.cancelled))
        } else {
            complete(with: .failure(PasskeyError.failed(error.localizedDescription)))
        }
    }
}

extension SecretsPasskeyAuthenticator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? ASPresentationAnchor()
    }
}

/// Owns the passkey-derived KEK and caches it for a few minutes so a burst of
/// encrypt/decrypt operations only prompts the user once (matches the web app's
/// 5-minute `cachedKek`). The KEK never persists anywhere.
@MainActor
final class SecretsKeyVault {
    private var cachedKEK: SymmetricKey?
    private var cachedAt: Date?
    private let ttl: TimeInterval = 5 * 60

    /// Returns the KEK, running a passkey PRF ceremony if the cache is cold.
    func kek() async throws -> SymmetricKey {
        if let cachedKEK, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cachedKEK
        }
        let authenticator = SecretsPasskeyAuthenticator()
        let prf = try await authenticator.evaluatePRF()
        let kek = SecretsCrypto.deriveKEK(prfOutput: prf)
        cachedKEK = kek
        cachedAt = Date()
        return kek
    }

    func clear() {
        cachedKEK = nil
        cachedAt = nil
    }
}
#endif
