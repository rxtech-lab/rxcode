import CryptoKit
import Foundation

/// Pure CryptoKit port of github-pm's `lib/secrets/crypto.ts`. Keeping this
/// byte-for-byte interoperable with the web app is the whole point: a secret
/// enrolled / encrypted in the browser must decrypt here and vice-versa.
///
/// The scheme:
/// - A 32-byte **PRF output** is extracted from the user's passkey (done in the
///   app layer via `AuthenticationServices`; this type never touches passkeys).
/// - The **KEK** (key-encryption key) is `HKDF-SHA256(prf, salt: ∅, info: "…/kek")`.
/// - Each user has an **ECDH P-256 keypair**; the private key is exported as a
///   JWK, AES-GCM-wrapped under the KEK, and stored server-side.
/// - Each environment has a random 32-byte **DEK**; the owner wraps it under
///   their KEK (`wrapMode: "kek"`), and it can also be sealed to another user's
///   public key (`wrapMode: "hpke"`).
/// - Files are AES-GCM encrypted under the DEK.
///
/// AES-GCM layout matches WebCrypto exactly: the `iv` (12 bytes) is stored
/// separately, and the `ciphertext` field is `rawCiphertext ‖ 16-byte tag`
/// (WebCrypto appends the tag; CryptoKit keeps them separate, so we concatenate
/// on the way out and split on the way in).
public enum SecretsCrypto {

    // MARK: - Constants (must match github-pm/lib/secrets/constants.ts)

    /// `github-pm-secrets-v1-prf-salt!!!` — the load-bearing PRF salt. Changing
    /// it invalidates every wrapped private key. 32 bytes.
    public static let prfSalt = Data("github-pm-secrets-v1-prf-salt!!!".utf8)

    /// HKDF `info` for deriving the KEK from PRF output.
    public static let hkdfInfoKEK = Data("github-pm-secrets-v1/kek".utf8)

    /// HKDF `info` for deriving an AES-GCM key from an ECDH shared secret (HPKE).
    public static let hkdfInfoHPKE = Data("github-pm-secrets-v1/hpke".utf8)

    /// WebAuthn relying-party identifier the passkeys are scoped to.
    public static let webAuthnRPID = "rxlab.app"

    public enum CryptoError: Error, LocalizedError {
        case badBase64(String)
        case ciphertextTooShort
        case invalidJWK
        case prfUnavailable

        public var errorDescription: String? {
            switch self {
            case .badBase64(let field): return "Malformed base64 in \(field)."
            case .ciphertextTooShort: return "Ciphertext is too short to contain an auth tag."
            case .invalidJWK: return "Stored private key is not a valid P-256 JWK."
            case .prfUnavailable: return "This passkey does not support the PRF extension."
            }
        }
    }

    // MARK: - KEK

    /// `HKDF-SHA256(prfOutput, salt: ∅, info: "github-pm-secrets-v1/kek")` → 256-bit AES key.
    public static func deriveKEK(prfOutput: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prfOutput),
            salt: Data(),
            info: hkdfInfoKEK,
            outputByteCount: 32
        )
    }

    // MARK: - AES-GCM (WebCrypto-compatible serialization)

    /// Encrypts `plaintext`, returning base64 `ciphertext` (`raw ‖ tag`) + base64 `iv`.
    public static func aesGcmEncrypt(
        key: SymmetricKey,
        plaintext: Data
    ) throws -> (ciphertext: String, iv: String) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var combined = Data(sealed.ciphertext)
        combined.append(sealed.tag)
        return (combined.base64EncodedString(), Data(nonce).base64EncodedString())
    }

    /// Decrypts a WebCrypto-style `{ciphertext: raw‖tag, iv}` pair.
    public static func aesGcmDecrypt(
        key: SymmetricKey,
        ciphertextB64: String,
        ivB64: String
    ) throws -> Data {
        guard let ctTag = Data(base64Encoded: ciphertextB64) else {
            throw CryptoError.badBase64("ciphertext")
        }
        guard let iv = Data(base64Encoded: ivB64) else {
            throw CryptoError.badBase64("iv")
        }
        guard ctTag.count >= 16 else { throw CryptoError.ciphertextTooShort }
        let tag = Data(ctTag.suffix(16))
        let ct = Data(ctTag.prefix(ctTag.count - 16))
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: ct,
            tag: tag
        )
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - User keypair (ECDH P-256)

    public struct UserKeypair {
        /// Base64 of the raw uncompressed public point (`0x04 ‖ X ‖ Y`, 65 bytes).
        public let publicKeyB64: String
        /// The private key, ready to wrap.
        public let privateKey: P256.KeyAgreement.PrivateKey
    }

    public static func generateUserKeypair() -> UserKeypair {
        let pk = P256.KeyAgreement.PrivateKey()
        return UserKeypair(
            publicKeyB64: pk.publicKey.x963Representation.base64EncodedString(),
            privateKey: pk
        )
    }

    public static func importPublicKey(b64: String) throws -> P256.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: b64) else { throw CryptoError.badBase64("publicKey") }
        return try P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    /// Serializes the private key as a WebCrypto-importable JWK (`kty/crv/x/y/d`).
    public static func privateKeyJWK(_ pk: P256.KeyAgreement.PrivateKey) -> [String: Any] {
        let pub = pk.publicKey.x963Representation // 0x04 ‖ X(32) ‖ Y(32)
        let x = pub.subdata(in: 1..<33)
        let y = pub.subdata(in: 33..<65)
        let d = pk.rawRepresentation // 32-byte scalar
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64urlEncode(x),
            "y": base64urlEncode(y),
            "d": base64urlEncode(d),
            "ext": true,
        ]
    }

    public static func importPrivateKeyJWK(_ jwk: [String: Any]) throws -> P256.KeyAgreement.PrivateKey {
        guard
            let xS = jwk["x"] as? String, let x = base64urlDecode(xS),
            let yS = jwk["y"] as? String, let y = base64urlDecode(yS),
            let dS = jwk["d"] as? String, let d = base64urlDecode(dS),
            x.count == 32, y.count == 32, d.count == 32
        else { throw CryptoError.invalidJWK }
        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)
        x963.append(d)
        return try P256.KeyAgreement.PrivateKey(x963Representation: x963)
    }

    /// AES-GCM-wraps the private key (as JWK JSON) under the KEK.
    public static func wrapPrivateKey(
        _ pk: P256.KeyAgreement.PrivateKey,
        kek: SymmetricKey
    ) throws -> (wrappedPrivateKey: String, wrapIv: String) {
        let json = try JSONSerialization.data(
            withJSONObject: privateKeyJWK(pk),
            options: [.sortedKeys]
        )
        let enc = try aesGcmEncrypt(key: kek, plaintext: json)
        return (wrappedPrivateKey: enc.ciphertext, wrapIv: enc.iv)
    }

    public static func unwrapPrivateKey(
        wrappedPrivateKey: String,
        wrapIv: String,
        kek: SymmetricKey
    ) throws -> P256.KeyAgreement.PrivateKey {
        let json = try aesGcmDecrypt(key: kek, ciphertextB64: wrappedPrivateKey, ivB64: wrapIv)
        guard let jwk = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CryptoError.invalidJWK
        }
        return try importPrivateKeyJWK(jwk)
    }

    // MARK: - DEK (per-environment data key)

    /// Generates a fresh 32-byte DEK, returning both the key and its raw bytes
    /// (the raw bytes are what get wrapped under a KEK / public key).
    public static func generateDEK() -> (key: SymmetricKey, rawBytes: Data) {
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        return (key, raw)
    }

    public static func importDEK(rawBytes: Data) -> SymmetricKey {
        SymmetricKey(data: rawBytes)
    }

    // MARK: - HPKE-style sealing (ECDH → HKDF → AES-GCM)

    private static func hpkeKey(shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: hkdfInfoHPKE,
            outputByteCount: 32
        )
    }

    /// Seals `plaintext` to `recipientPublicKey`, returning the ciphertext, iv
    /// and the ephemeral public key (base64 raw point) needed to unseal.
    public static func sealToPublicKey(
        plaintext: Data,
        recipientPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> (ciphertext: String, wrapIv: String, ephemeralPublicKey: String) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let aesKey = hpkeKey(shared: shared)
        let enc = try aesGcmEncrypt(key: aesKey, plaintext: plaintext)
        return (
            enc.ciphertext,
            enc.iv,
            ephemeral.publicKey.x963Representation.base64EncodedString()
        )
    }

    public static func unsealWithPrivateKey(
        ciphertext: String,
        ivB64: String,
        ephemeralPublicKeyB64: String,
        recipientPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let ephemeralPub = try importPublicKey(b64: ephemeralPublicKeyB64)
        let shared = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPub)
        return try aesGcmDecrypt(
            key: hpkeKey(shared: shared),
            ciphertextB64: ciphertext,
            ivB64: ivB64
        )
    }

    // MARK: - File-level helpers

    public static func encryptFile(
        plaintext: String,
        dek: SymmetricKey
    ) throws -> (ciphertext: String, iv: String, size: Int) {
        let bytes = Data(plaintext.utf8)
        let enc = try aesGcmEncrypt(key: dek, plaintext: bytes)
        return (enc.ciphertext, enc.iv, bytes.count)
    }

    public static func decryptFile(
        ciphertextB64: String,
        ivB64: String,
        dek: SymmetricKey
    ) throws -> String {
        let data = try aesGcmDecrypt(key: dek, ciphertextB64: ciphertextB64, ivB64: ivB64)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - base64url (JWK fields)

    public static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64urlDecode(_ s: String) -> Data? {
        var str = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}
