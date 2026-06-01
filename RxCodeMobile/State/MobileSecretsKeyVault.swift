import AuthenticationServices
import CryptoKit
import Foundation
import RxCodeCore
import UIKit
import os.log

/// Runs a passkey assertion purely to unlock the WebAuthn PRF extension, so the
/// phone can derive the secrets KEK from the user's iCloud-synced `rxlab.app`
/// passkey — the same credential and PRF salt the desktop uses, producing the
/// identical KEK. The assertion signature is not verified by anyone; we only
/// want the PRF output bytes. iOS counterpart of the macOS
/// `SecretsPasskeyAuthenticator` (UIKit presentation anchor).
@MainActor
final class MobileSecretsPasskeyAuthenticator: NSObject {

    enum PasskeyError: LocalizedError {
        case cancelled
        case prfUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return String(localized: "Passkey authentication was cancelled.")
            case .prfUnavailable:
                return String(localized: "This passkey can't unlock secrets — it doesn't support the PRF extension. Use the passkey you enrolled with.")
            case .failed(let detail):
                return String(localized: "Passkey authentication failed: \(detail)")
            }
        }
    }

    private var continuation: CheckedContinuation<Data, Error>?
    private var retainedSelf: MobileSecretsPasskeyAuthenticator?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "SecretsPasskey")

    /// Performs a discoverable assertion with the PRF extension evaluating
    /// `salt`, returning the 32-byte PRF output.
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

extension MobileSecretsPasskeyAuthenticator: ASAuthorizationControllerDelegate {
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

extension MobileSecretsPasskeyAuthenticator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}

/// Owns the passkey-derived KEK and caches it for a few minutes so a burst of
/// encrypt/decrypt operations only prompts once. The KEK never persists. iOS
/// counterpart of the macOS `SecretsKeyVault`.
@MainActor
final class MobileSecretsKeyVault {
    private var cachedKEK: SymmetricKey?
    private var cachedAt: Date?
    private let ttl: TimeInterval = 5 * 60

    /// Returns the KEK, running a passkey PRF ceremony if the cache is cold.
    func kek() async throws -> SymmetricKey {
        if let cachedKEK, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cachedKEK
        }
        let authenticator = MobileSecretsPasskeyAuthenticator()
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
