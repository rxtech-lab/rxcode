package app.rxlab.rxcode.crypto

import app.rxlab.rxcode.proto.SecretsEnvironmentKey
import app.rxlab.rxcode.proto.SecretsUserKey
import org.bouncycastle.asn1.x9.ECNamedCurveTable
import org.bouncycastle.crypto.agreement.ECDHBasicAgreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.ECKeyPairGenerator
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.crypto.params.ECKeyGenerationParameters
import org.bouncycastle.crypto.params.ECPrivateKeyParameters
import org.bouncycastle.crypto.params.ECPublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.json.JSONObject
import java.math.BigInteger
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Byte-for-byte port of `RxCodeCore/Secrets/SecretsCrypto.swift` (itself a port
 * of github-pm's `lib/secrets/crypto.ts`). Keeping this interoperable with the
 * macOS/iOS/web implementations is the whole point: a secret encrypted on any
 * platform must decrypt here and vice-versa.
 *
 * Scheme:
 * - 32-byte **PRF output** comes from the user's passkey (see [SecretsKeyVault]).
 * - **KEK** = `HKDF-SHA256(prf, salt: ∅, info: ".../kek")`.
 * - Each user has an **ECDH P-256 keypair**; the private key is a JWK
 *   AES-GCM-wrapped under the KEK.
 * - Each environment has a random 32-byte **DEK**, wrapped under the owner's KEK
 *   (`wrapMode: "kek"`) or sealed to a public key (`wrapMode: "hpke"`).
 * - Files are AES-GCM encrypted under the DEK.
 *
 * AES-GCM layout matches WebCrypto: `iv` (12 bytes) stored separately, and
 * `ciphertext` is `rawCiphertext ‖ 16-byte tag` (JCA's GCM already appends the
 * tag to its output, matching WebCrypto).
 */
object SecretsCrypto {

    // Constants — must match github-pm/lib/secrets/constants.ts.
    val prfSalt: ByteArray = "github-pm-secrets-v1-prf-salt!!!".toByteArray(Charsets.UTF_8)
    private val hkdfInfoKEK = "github-pm-secrets-v1/kek".toByteArray(Charsets.UTF_8)
    private val hkdfInfoHPKE = "github-pm-secrets-v1/hpke".toByteArray(Charsets.UTF_8)
    const val WEBAUTHN_RP_ID = "rxlab.app"

    class CryptoException(message: String) : Exception(message)

    private val x9 = ECNamedCurveTable.getByName("P-256")
    private val domain = ECDomainParameters(x9.curve, x9.g, x9.n, x9.h)
    private val random = SecureRandom()

    private fun b64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)
    private fun b64d(s: String): ByteArray = Base64.getDecoder().decode(s)

    // MARK: - KEK

    /** `HKDF-SHA256(prf, salt: ∅, info: ".../kek")` → 32-byte AES key. */
    fun deriveKEK(prfOutput: ByteArray): ByteArray =
        hkdf(prfOutput, ByteArray(0), hkdfInfoKEK, 32)

    private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val gen = HKDFBytesGenerator(SHA256Digest())
        gen.init(HKDFParameters(ikm, salt, info))
        val out = ByteArray(length)
        gen.generateBytes(out, 0, length)
        return out
    }

    // MARK: - AES-GCM (WebCrypto-compatible)

    /** Encrypts, returning base64 `ciphertext` (`raw ‖ tag`) + base64 `iv`. */
    fun aesGcmEncrypt(key: ByteArray, plaintext: ByteArray): Pair<String, String> {
        val iv = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val combined = cipher.doFinal(plaintext) // raw ‖ tag
        return b64(combined) to b64(iv)
    }

    fun aesGcmDecrypt(key: ByteArray, ciphertextB64: String, ivB64: String): ByteArray {
        val ctTag = b64d(ciphertextB64)
        val iv = b64d(ivB64)
        if (ctTag.size < 16) throw CryptoException("Ciphertext is too short to contain an auth tag.")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return cipher.doFinal(ctTag)
    }

    // MARK: - DEK

    fun generateDEK(): ByteArray = ByteArray(32).also { random.nextBytes(it) }

    // MARK: - ECDH P-256 / HPKE

    private fun bigIntTo32(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size == 33 && raw[0] == 0.toByte() -> raw.copyOfRange(1, 33)
            raw.size < 32 -> ByteArray(32 - raw.size) + raw
            else -> raw.copyOfRange(raw.size - 32, raw.size)
        }
    }

    private fun importPublicKey(b64: String): ECPublicKeyParameters {
        val point = domain.curve.decodePoint(b64d(b64))
        return ECPublicKeyParameters(point, domain)
    }

    private fun ecdhSharedSecret(
        priv: ECPrivateKeyParameters,
        pub: ECPublicKeyParameters,
    ): ByteArray {
        val agree = ECDHBasicAgreement()
        agree.init(priv)
        return bigIntTo32(agree.calculateAgreement(pub)) // X coordinate, like WebCrypto/CryptoKit
    }

    private fun hpkeKey(shared: ByteArray): ByteArray = hkdf(shared, ByteArray(0), hkdfInfoHPKE, 32)

    fun sealToPublicKey(plaintext: ByteArray, recipientPublicKeyB64: String): Triple<String, String, String> {
        val recipient = importPublicKey(recipientPublicKeyB64)
        val gen = ECKeyPairGenerator().apply { init(ECKeyGenerationParameters(domain, random)) }
        val ephemeral = gen.generateKeyPair()
        val ephPriv = ephemeral.private as ECPrivateKeyParameters
        val ephPub = ephemeral.public as ECPublicKeyParameters
        val shared = ecdhSharedSecret(ephPriv, recipient)
        val enc = aesGcmEncrypt(hpkeKey(shared), plaintext)
        val ephB64 = b64(ephPub.q.getEncoded(false))
        return Triple(enc.first, enc.second, ephB64)
    }

    fun unsealWithPrivateKey(
        ciphertextB64: String,
        ivB64: String,
        ephemeralPublicKeyB64: String,
        recipientPrivateKey: ECPrivateKeyParameters,
    ): ByteArray {
        val ephPub = importPublicKey(ephemeralPublicKeyB64)
        val shared = ecdhSharedSecret(recipientPrivateKey, ephPub)
        return aesGcmDecrypt(hpkeKey(shared), ciphertextB64, ivB64)
    }

    // MARK: - User private key (JWK)

    private fun importPrivateKeyJWK(jwk: JSONObject): ECPrivateKeyParameters {
        val d = jwk.optString("d", "")
        if (d.isBlank()) throw CryptoException("Stored private key is not a valid P-256 JWK.")
        val dBytes = base64urlDecode(d) ?: throw CryptoException("Malformed JWK private scalar.")
        if (dBytes.size != 32) throw CryptoException("Stored private key is not a valid P-256 JWK.")
        return ECPrivateKeyParameters(BigInteger(1, dBytes), domain)
    }

    fun unwrapPrivateKey(wrappedPrivateKey: String, wrapIv: String, kek: ByteArray): ECPrivateKeyParameters {
        val json = aesGcmDecrypt(kek, wrappedPrivateKey, wrapIv)
        return importPrivateKeyJWK(JSONObject(String(json, Charsets.UTF_8)))
    }

    // MARK: - Flows (mirror SecretsFlows.swift)

    /** Fresh DEK wrapped under the owner KEK (`wrapMode: "kek"`). */
    fun buildOwnerEnvironmentKey(kek: ByteArray): Pair<app.rxlab.rxcode.proto.EnvironmentKeyBody, ByteArray> {
        val dek = generateDEK()
        val wrap = aesGcmEncrypt(kek, dek)
        val body = app.rxlab.rxcode.proto.EnvironmentKeyBody(
            wrapMode = "kek",
            wrappedDek = wrap.first,
            wrapIv = wrap.second,
            ephemeralPublicKey = null,
        )
        return body to dek
    }

    /** Resolves an environment key row into the raw DEK bytes. */
    fun unwrapDEK(
        envKey: SecretsEnvironmentKey,
        kek: ByteArray,
        userPrivateKey: ECPrivateKeyParameters?,
    ): ByteArray = when (envKey.wrapMode) {
        "kek" -> {
            val iv = envKey.wrapIv ?: throw CryptoException("Wrapped key is missing its IV.")
            aesGcmDecrypt(kek, envKey.wrappedDek, iv)
        }
        "hpke" -> {
            val priv = userPrivateKey
                ?: throw CryptoException("This environment was shared with you; your enrollment key is required to open it.")
            val iv = envKey.wrapIv
            val eph = envKey.ephemeralPublicKey
            if (iv == null || eph == null) throw CryptoException("Shared key is missing its ephemeral public key or IV.")
            unsealWithPrivateKey(envKey.wrappedDek, iv, eph, priv)
        }
        else -> throw CryptoException("Unsupported wrap mode: ${envKey.wrapMode}.")
    }

    fun unwrapUserPrivateKey(userKey: SecretsUserKey, kek: ByteArray): ECPrivateKeyParameters? {
        val wrapped = userKey.wrappedPrivateKey ?: return null
        val iv = userKey.wrapIv ?: return null
        return unwrapPrivateKey(wrapped, iv, kek)
    }

    // MARK: - File helpers

    fun encryptFile(plaintext: String, dek: ByteArray): Triple<String, String, Int> {
        val bytes = plaintext.toByteArray(Charsets.UTF_8)
        val enc = aesGcmEncrypt(dek, bytes)
        return Triple(enc.first, enc.second, bytes.size)
    }

    fun decryptFile(ciphertextB64: String, ivB64: String, dek: ByteArray): String =
        String(aesGcmDecrypt(dek, ciphertextB64, ivB64), Charsets.UTF_8)

    // MARK: - base64url

    private fun base64urlDecode(s: String): ByteArray? {
        var str = s.replace('-', '+').replace('_', '/')
        while (str.length % 4 != 0) str += "="
        return runCatching { Base64.getDecoder().decode(str) }.getOrNull()
    }
}
