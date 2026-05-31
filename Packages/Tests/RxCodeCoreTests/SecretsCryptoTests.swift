import CryptoKit
import Foundation
import Testing
@testable import RxCodeCore

/// Cross-implementation interop tests. The vectors below were produced by
/// running github-pm's exact WebCrypto algorithm (`lib/secrets/crypto.ts`) in
/// Node. If these pass, a secret encrypted in the web app decrypts here and
/// vice-versa. See `/tmp/secrets_vectors.mjs` for the generator.
@Suite("Secrets crypto interop")
struct SecretsCryptoTests {

    // PRF output = bytes 0..31.
    let prfBase64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    let kekRawBase64 = "ULZP/vEtqjzXo4BBS9LgP3+ArlkcvarPQh5oz9+UOn8="
    let aesIvBase64 = "ZGVmZ2hpamtsbW5v"
    let aesCiphertextBase64 = "oMVg1z0otjpPgx+gu9Vp871a7BzkTrRWgAAUADGTGCn50M0c"
    let plaintext = "HELLO=world\nFOO=bar\n"

    // HPKE vector.
    let recipientPublicKeyBase64 = "BAdm7iOjfExHY0laeUByH7D1i/BU6sNQa0rBmmx+RnwmcKrtopQzEjuXoUmq7+ogv+nxdmQrwkuDnGLHmokQEA4="
    let recipientJWK: [String: Any] = [
        "kty": "EC", "crv": "P-256",
        "x": "B2buI6N8TEdjSVp5QHIfsPWL8FTqw1BrSsGabH5GfCY",
        "y": "cKrtopQzEjuXoUmq7-ogv-nxdmQrwkuDnGLHmokQEA4",
        "d": "dBSLtp7PjaVJb9TG_HT2i8KPQX4teVcXXivvX2gXwXo",
    ]
    let hpkeEphemeralPublicKeyBase64 = "BEqBsBWx/ZTkwMrTFhgrr3QqfCF2KgOMK/0XBhskDwAs879yGNm+sbpggasWCAerBX8LW+2vtWUa4Esnj8COoRU="
    let hpkeIvBase64 = "BwcHBwcHBwcHBwcH"
    let hpkeCiphertextBase64 = "emwdBPA8uXNXZOzWZ7qHPrjd25HXp2lIPGndMx0D9KtK7IVa"

    private func data(_ b64: String) -> Data { Data(base64Encoded: b64)! }

    @Test("PRF salt is the documented 32-byte constant")
    func prfSaltConstant() {
        #expect(SecretsCrypto.prfSalt.count == 32)
        #expect(SecretsCrypto.prfSalt == Data("github-pm-secrets-v1-prf-salt!!!".utf8))
    }

    @Test("KEK derivation matches WebCrypto HKDF (known answer)")
    func kekKnownAnswer() {
        let kek = SecretsCrypto.deriveKEK(prfOutput: data(prfBase64))
        let raw = kek.withUnsafeBytes { Data($0) }
        #expect(raw == data(kekRawBase64))
    }

    @Test("AES-GCM decrypts WebCrypto-produced ciphertext (tag layout)")
    func aesGcmDecryptsWebVector() throws {
        let kek = SecretsCrypto.deriveKEK(prfOutput: data(prfBase64))
        let out = try SecretsCrypto.aesGcmDecrypt(
            key: kek, ciphertextB64: aesCiphertextBase64, ivB64: aesIvBase64
        )
        #expect(String(decoding: out, as: UTF8.self) == plaintext)
    }

    @Test("AES-GCM round-trips")
    func aesGcmRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let enc = try SecretsCrypto.aesGcmEncrypt(key: key, plaintext: Data(plaintext.utf8))
        let dec = try SecretsCrypto.aesGcmDecrypt(key: key, ciphertextB64: enc.ciphertext, ivB64: enc.iv)
        #expect(String(decoding: dec, as: UTF8.self) == plaintext)
    }

    @Test("Imports a WebCrypto JWK private key and reproduces its public point")
    func jwkImport() throws {
        let priv = try SecretsCrypto.importPrivateKeyJWK(recipientJWK)
        #expect(priv.publicKey.x963Representation == data(recipientPublicKeyBase64))
    }

    @Test("JWK export/import round-trips")
    func jwkRoundTrip() throws {
        let kp = SecretsCrypto.generateUserKeypair()
        let jwk = SecretsCrypto.privateKeyJWK(kp.privateKey)
        let reimported = try SecretsCrypto.importPrivateKeyJWK(jwk)
        #expect(reimported.rawRepresentation == kp.privateKey.rawRepresentation)
    }

    @Test("HPKE unseal of WebCrypto-sealed payload")
    func hpkeUnsealWebVector() throws {
        let priv = try SecretsCrypto.importPrivateKeyJWK(recipientJWK)
        let out = try SecretsCrypto.unsealWithPrivateKey(
            ciphertext: hpkeCiphertextBase64,
            ivB64: hpkeIvBase64,
            ephemeralPublicKeyB64: hpkeEphemeralPublicKeyBase64,
            recipientPrivateKey: priv
        )
        #expect(String(decoding: out, as: UTF8.self) == plaintext)
    }

    @Test("HPKE seal/unseal round-trips")
    func hpkeRoundTrip() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let sealed = try SecretsCrypto.sealToPublicKey(
            plaintext: Data(plaintext.utf8),
            recipientPublicKey: recipient.publicKey
        )
        let out = try SecretsCrypto.unsealWithPrivateKey(
            ciphertext: sealed.ciphertext,
            ivB64: sealed.wrapIv,
            ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
            recipientPrivateKey: recipient
        )
        #expect(String(decoding: out, as: UTF8.self) == plaintext)
    }

    @Test("Private key wrap/unwrap under KEK round-trips")
    func wrapUnwrapPrivateKey() throws {
        let kek = SecretsCrypto.deriveKEK(prfOutput: data(prfBase64))
        let kp = SecretsCrypto.generateUserKeypair()
        let wrap = try SecretsCrypto.wrapPrivateKey(kp.privateKey, kek: kek)
        let unwrapped = try SecretsCrypto.unwrapPrivateKey(
            wrappedPrivateKey: wrap.wrappedPrivateKey, wrapIv: wrap.wrapIv, kek: kek
        )
        #expect(unwrapped.rawRepresentation == kp.privateKey.rawRepresentation)
    }

    @Test("DEK owner-wrap + unwrap round-trips, file decrypts")
    func dekFlow() throws {
        let kek = SecretsCrypto.deriveKEK(prfOutput: data(prfBase64))
        let owner = try SecretsFlows.buildOwnerEnvironmentKey(kek: kek)
        let file = try SecretsCrypto.encryptFile(plaintext: plaintext, dek: owner.dek)

        let envKey = SecretsEnvironmentKey(
            wrapMode: owner.body.wrapMode,
            wrappedDek: owner.body.wrappedDek,
            wrapIv: owner.body.wrapIv,
            ephemeralPublicKey: owner.body.ephemeralPublicKey
        )
        let dek = try SecretsFlows.unwrapDEK(envKey: envKey, kek: kek, userPrivateKey: nil)
        let decrypted = try SecretsCrypto.decryptFile(ciphertextB64: file.ciphertext, ivB64: file.iv, dek: dek)
        #expect(decrypted == plaintext)
    }
}
