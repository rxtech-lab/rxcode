import Foundation
import CryptoKit

/// Symmetric envelope sealing / opening using a static-static X25519 ECDH
/// derived key. The derivation salt is the byte-sorted concatenation of the
/// two pubkeys so both ends always derive the same `SymmetricKey`.
public enum SessionCrypto {
    /// Used as the HKDF info string. Bump if the wire format ever changes.
    public static let kdfInfo = Data("rxcode-sync/v1".utf8)

    public enum CryptoError: Error {
        case invalidPubkeyLength
        case sealFailed
        case openFailed
    }

    /// Encrypt `plaintext` so it can be opened only by the holder of the
    /// private key paired with `recipient`.
    public static func seal(
        plaintext: Data,
        sender: Curve25519.KeyAgreement.PrivateKey,
        recipient: Curve25519.KeyAgreement.PublicKey,
        salt: Data? = nil
    ) throws -> (nonce: Data, ciphertext: Data) {
        let key = try deriveKey(
            privateKey: sender,
            publicKey: recipient,
            extraSalt: salt
        )
        let nonceBytes = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        let nonceData = Data(nonceBytes)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return (nonceData, sealed.ciphertext + sealed.tag)
    }

    /// Decrypt an envelope addressed to `recipient` from `sender`.
    public static func open(
        ciphertext: Data,
        nonce: Data,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        sender: Curve25519.KeyAgreement.PublicKey,
        salt: Data? = nil
    ) throws -> Data {
        let key = try deriveKey(
            privateKey: recipient,
            publicKey: sender,
            extraSalt: salt
        )
        // ChaChaPoly tag is the last 16 bytes
        guard ciphertext.count >= 16 else { throw CryptoError.openFailed }
        let tag = ciphertext.suffix(16)
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)
        let sealed = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(sealed, using: key)
    }

    private static func deriveKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        extraSalt: Data?
    ) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        var salt = sortedConcat(privateKey.publicKey.rawRepresentation, publicKey.rawRepresentation)
        if let extraSalt { salt.append(extraSalt) }
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: kdfInfo,
            outputByteCount: 32
        )
    }

    private static func sortedConcat(_ a: Data, _ b: Data) -> Data {
        a.lexicographicallyPrecedes(b) ? a + b : b + a
    }
}
