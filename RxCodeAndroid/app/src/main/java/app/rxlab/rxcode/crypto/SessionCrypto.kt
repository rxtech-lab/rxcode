package app.rxlab.rxcode.crypto

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.engines.ChaCha7539Engine
import org.bouncycastle.crypto.macs.Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Port of `Packages/Sources/RxCodeSync/Crypto/SessionCrypto.swift`.
 *
 * X25519 ECDH + HKDF-SHA256 derives a 32-byte symmetric key, then ChaCha20-Poly1305
 * (IETF, 12-byte nonce) seals plaintext as `ciphertext || tag(16)`. The HKDF salt
 * is the byte-sorted concatenation of both pubkeys, optionally with extra salt
 * appended — both peers derive the same key regardless of who originated the call.
 */
object SessionCrypto {
    private const val KDF_INFO = "rxcode-sync/v1"
    private val rng = SecureRandom()

    data class Sealed(val nonce: ByteArray, val ciphertext: ByteArray)

    fun seal(
        plaintext: ByteArray,
        senderPrivate: X25519PrivateKeyParameters,
        recipientPublic: X25519PublicKeyParameters,
        extraSalt: ByteArray? = null
    ): Sealed {
        val senderPublic = senderPrivate.generatePublicKey()
        val key = deriveKey(senderPrivate, recipientPublic, senderPublic.encoded, recipientPublic.encoded, extraSalt)
        val nonce = ByteArray(12).also { rng.nextBytes(it) }
        val (ct, tag) = chachaPolySeal(key, nonce, plaintext)
        return Sealed(nonce, ct + tag)
    }

    fun open(
        ciphertextWithTag: ByteArray,
        nonce: ByteArray,
        recipientPrivate: X25519PrivateKeyParameters,
        senderPublic: X25519PublicKeyParameters,
        extraSalt: ByteArray? = null
    ): ByteArray {
        require(ciphertextWithTag.size >= 16) { "ciphertext too short" }
        require(nonce.size == 12) { "nonce must be 12 bytes" }
        val recipientPublic = recipientPrivate.generatePublicKey()
        val key = deriveKey(recipientPrivate, senderPublic, recipientPublic.encoded, senderPublic.encoded, extraSalt)
        val tag = ciphertextWithTag.copyOfRange(ciphertextWithTag.size - 16, ciphertextWithTag.size)
        val ct = ciphertextWithTag.copyOfRange(0, ciphertextWithTag.size - 16)
        return chachaPolyOpen(key, nonce, ct, tag)
    }

    private fun deriveKey(
        ourPrivate: X25519PrivateKeyParameters,
        theirPublic: X25519PublicKeyParameters,
        ourPubBytes: ByteArray,
        theirPubBytes: ByteArray,
        extraSalt: ByteArray?
    ): ByteArray {
        val agreement = X25519Agreement().apply { init(ourPrivate) }
        val shared = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(theirPublic, shared, 0)
        val sortedSalt = sortedConcat(ourPubBytes, theirPubBytes)
        val salt = if (extraSalt != null) sortedSalt + extraSalt else sortedSalt
        return hkdfSha256(shared, salt, KDF_INFO.toByteArray(Charsets.UTF_8), 32)
    }

    private fun sortedConcat(a: ByteArray, b: ByteArray): ByteArray =
        if (lexicographicallyPrecedes(a, b)) a + b else b + a

    private fun lexicographicallyPrecedes(a: ByteArray, b: ByteArray): Boolean {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val ai = a[i].toInt() and 0xFF
            val bi = b[i].toInt() and 0xFF
            if (ai != bi) return ai < bi
        }
        return a.size < b.size
    }

    // RFC 5869 HKDF-SHA256
    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmacSha256(salt, ikm)
        var t = ByteArray(0)
        val out = ByteArray(length)
        var generated = 0
        var counter = 1
        while (generated < length) {
            val input = t + info + byteArrayOf(counter.toByte())
            t = hmacSha256(prk, input)
            val take = minOf(t.size, length - generated)
            System.arraycopy(t, 0, out, generated, take)
            generated += take
            counter += 1
        }
        return out
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    // ChaCha20-Poly1305 (IETF / RFC 8439) implemented over BouncyCastle's
    // primitives so we don't depend on a single provider's "ChaCha20-Poly1305"
    // Cipher availability across API levels.
    private fun chachaPolySeal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray): Pair<ByteArray, ByteArray> {
        val polyKey = chachaBlockZero(key, nonce)
        val ct = chacha20Encrypt(key, nonce, plaintext)
        val tag = poly1305Tag(polyKey, ByteArray(0), ct)
        return ct to tag
    }

    private fun chachaPolyOpen(key: ByteArray, nonce: ByteArray, ciphertext: ByteArray, tag: ByteArray): ByteArray {
        val polyKey = chachaBlockZero(key, nonce)
        val expected = poly1305Tag(polyKey, ByteArray(0), ciphertext)
        if (!constantTimeEquals(expected, tag)) throw SecurityException("Poly1305 tag mismatch")
        return chacha20Encrypt(key, nonce, ciphertext)
    }

    private fun chachaBlockZero(key: ByteArray, nonce: ByteArray): ByteArray {
        val engine = ChaCha7539Engine()
        engine.init(true, ParametersWithIV(KeyParameter(key), nonce))
        val out = ByteArray(64)
        engine.processBytes(ByteArray(64), 0, 64, out, 0)
        return out.copyOfRange(0, 32)
    }

    private fun chacha20Encrypt(key: ByteArray, nonce: ByteArray, input: ByteArray): ByteArray {
        val engine = ChaCha7539Engine()
        engine.init(true, ParametersWithIV(KeyParameter(key), nonce))
        // Consume the first 64-byte block so encryption starts at counter=1
        // (RFC 8439: block 0 is reserved for the Poly1305 one-time key).
        val sink = ByteArray(64)
        engine.processBytes(ByteArray(64), 0, 64, sink, 0)
        val out = ByteArray(input.size)
        engine.processBytes(input, 0, input.size, out, 0)
        return out
    }

    private fun poly1305Tag(key: ByteArray, aad: ByteArray, ciphertext: ByteArray): ByteArray {
        val mac = Poly1305()
        mac.init(KeyParameter(key))
        val aadPadded = padTo16(aad)
        val ctPadded = padTo16(ciphertext)
        mac.update(aadPadded, 0, aadPadded.size)
        mac.update(ctPadded, 0, ctPadded.size)
        val lengths = ByteArray(16)
        writeLeUInt64(lengths, 0, aad.size.toLong())
        writeLeUInt64(lengths, 8, ciphertext.size.toLong())
        mac.update(lengths, 0, 16)
        val tag = ByteArray(16)
        mac.doFinal(tag, 0)
        return tag
    }

    private fun padTo16(input: ByteArray): ByteArray {
        val rem = input.size % 16
        if (rem == 0) return input
        return input + ByteArray(16 - rem)
    }

    private fun writeLeUInt64(dst: ByteArray, offset: Int, value: Long) {
        for (i in 0 until 8) dst[offset + i] = ((value ushr (8 * i)) and 0xFF).toByte()
    }

    private fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }
}
