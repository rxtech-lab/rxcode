import CryptoKit
import Foundation

/// High-level helpers that combine `SecretsCrypto` primitives with the DTO
/// models — mirrors github-pm's `lib/secrets/flows.ts`. The passkey-derived KEK
/// is always supplied by the caller (the app layer runs the passkey ceremony).
public enum SecretsFlows {

    public enum FlowError: Error, LocalizedError {
        case missingWrapIv
        case missingHPKEMaterial
        case missingUserPrivateKey
        case unknownWrapMode(String)

        public var errorDescription: String? {
            switch self {
            case .missingWrapIv: return "Wrapped key is missing its IV."
            case .missingHPKEMaterial: return "Shared key is missing its ephemeral public key or IV."
            case .missingUserPrivateKey: return "This environment was shared with you; your enrollment key is required to open it."
            case .unknownWrapMode(let m): return "Unsupported wrap mode: \(m)."
            }
        }
    }

    // MARK: - Enrollment

    public struct EnrollmentResult {
        public let body: EnrollKeyBody
        public let privateKey: P256.KeyAgreement.PrivateKey
    }

    /// Generates a keypair and wraps the private key under `kek`.
    public static func enroll(kek: SymmetricKey) throws -> EnrollmentResult {
        let kp = SecretsCrypto.generateUserKeypair()
        let wrap = try SecretsCrypto.wrapPrivateKey(kp.privateKey, kek: kek)
        return EnrollmentResult(
            body: EnrollKeyBody(
                publicKey: kp.publicKeyB64,
                wrappedPrivateKey: wrap.wrappedPrivateKey,
                wrapIv: wrap.wrapIv
            ),
            privateKey: kp.privateKey
        )
    }

    // MARK: - Environment creation

    public struct OwnerEnvironmentKey {
        public let body: EnvironmentKeyBody
        public let dek: SymmetricKey
    }

    /// Generates a fresh DEK and wraps it under the owner's KEK (`wrapMode: "kek"`).
    public static func buildOwnerEnvironmentKey(kek: SymmetricKey) throws -> OwnerEnvironmentKey {
        let dek = SecretsCrypto.generateDEK()
        let wrap = try SecretsCrypto.aesGcmEncrypt(key: kek, plaintext: dek.rawBytes)
        return OwnerEnvironmentKey(
            body: EnvironmentKeyBody(
                wrapMode: "kek",
                wrappedDek: wrap.ciphertext,
                wrapIv: wrap.iv,
                ephemeralPublicKey: nil
            ),
            dek: dek.key
        )
    }

    // MARK: - Unwrapping a DEK from a stored environment key

    /// Resolves a `SecretsEnvironmentKey` row into a usable DEK. `kek` is the
    /// caller's passkey-derived key; `userPrivateKey` is only needed for
    /// HPKE-shared environments (unwrap it from the user's enrollment record
    /// first via ``unwrapUserPrivateKey(_:kek:)``).
    public static func unwrapDEK(
        envKey: SecretsEnvironmentKey,
        kek: SymmetricKey,
        userPrivateKey: P256.KeyAgreement.PrivateKey?
    ) throws -> SymmetricKey {
        switch envKey.wrapMode {
        case "kek":
            guard let iv = envKey.wrapIv else { throw FlowError.missingWrapIv }
            let raw = try SecretsCrypto.aesGcmDecrypt(
                key: kek, ciphertextB64: envKey.wrappedDek, ivB64: iv
            )
            return SecretsCrypto.importDEK(rawBytes: raw)
        case "hpke":
            guard let priv = userPrivateKey else { throw FlowError.missingUserPrivateKey }
            guard let iv = envKey.wrapIv, let eph = envKey.ephemeralPublicKey else {
                throw FlowError.missingHPKEMaterial
            }
            let raw = try SecretsCrypto.unsealWithPrivateKey(
                ciphertext: envKey.wrappedDek,
                ivB64: iv,
                ephemeralPublicKeyB64: eph,
                recipientPrivateKey: priv
            )
            return SecretsCrypto.importDEK(rawBytes: raw)
        default:
            throw FlowError.unknownWrapMode(envKey.wrapMode)
        }
    }

    /// Unwraps the user's ECDH private key from their enrollment record.
    public static func unwrapUserPrivateKey(
        _ userKey: SecretsUserKey,
        kek: SymmetricKey
    ) throws -> P256.KeyAgreement.PrivateKey? {
        guard let wrapped = userKey.wrappedPrivateKey, let iv = userKey.wrapIv else { return nil }
        return try SecretsCrypto.unwrapPrivateKey(wrappedPrivateKey: wrapped, wrapIv: iv, kek: kek)
    }
}
