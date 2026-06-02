package app.rxlab.rxcode.crypto

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64

/**
 * Owns the passkey-derived secrets KEK and caches it for a few minutes so a
 * burst of encrypt/decrypt operations only prompts once. The KEK never
 * persists. Android counterpart of iOS `MobileSecretsKeyVault`.
 *
 * The KEK is derived from the WebAuthn PRF output of the user's `rxlab.app`
 * passkey — the same credential and PRF salt the Mac/web use, so the derived
 * KEK is identical across platforms and on-device encryption/decryption
 * interoperates. Requires a passkey synced to this device (Google Password
 * Manager) whose provider supports the PRF extension.
 */
class SecretsKeyVault {
    private var cachedKEK: ByteArray? = null
    private var cachedAtMs: Long = 0
    private val ttlMs = 5 * 60 * 1000L
    private val random = SecureRandom()

    class PasskeyException(message: String) : Exception(message)

    /** Returns the KEK, running a passkey PRF ceremony when the cache is cold. */
    suspend fun kek(context: Context, nowMs: Long): ByteArray {
        cachedKEK?.let { if (nowMs - cachedAtMs < ttlMs) return it }
        val prf = evaluatePRF(context)
        val kek = SecretsCrypto.deriveKEK(prf)
        cachedKEK = kek
        cachedAtMs = nowMs
        return kek
    }

    fun clear() {
        cachedKEK = null
        cachedAtMs = 0
    }

    private suspend fun evaluatePRF(context: Context): ByteArray {
        val challenge = ByteArray(32).also { random.nextBytes(it) }
        val requestJson = buildRequestJson(
            challengeB64Url = base64url(challenge),
            saltB64Url = base64url(SecretsCrypto.prfSalt),
        )
        val option = GetPublicKeyCredentialOption(requestJson)
        val request = GetCredentialRequest(listOf(option))
        val manager = CredentialManager.create(context)

        val response = try {
            manager.getCredential(context, request)
        } catch (e: GetCredentialCancellationException) {
            throw PasskeyException("Passkey authentication was cancelled.")
        } catch (e: GetCredentialException) {
            throw PasskeyException("Passkey authentication failed: ${e.message ?: e.type}")
        }

        val credential = response.credential as? PublicKeyCredential
            ?: throw PasskeyException("Unexpected passkey credential.")
        val json = JSONObject(credential.authenticationResponseJson)
        val first = json
            .optJSONObject("clientExtensionResults")
            ?.optJSONObject("prf")
            ?.optJSONObject("results")
            ?.optString("first", "")
            ?.takeIf { it.isNotBlank() }
            ?: throw PasskeyException(
                "This passkey can't unlock secrets — it doesn't support the PRF extension. " +
                    "Use the passkey you enrolled with."
            )
        return base64urlDecode(first)
            ?: throw PasskeyException("Malformed PRF result from the passkey.")
    }

    private fun buildRequestJson(challengeB64Url: String, saltB64Url: String): String =
        JSONObject().apply {
            put("challenge", challengeB64Url)
            put("rpId", SecretsCrypto.WEBAUTHN_RP_ID)
            put("userVerification", "required")
            put("timeout", 60_000)
            put(
                "extensions",
                JSONObject().put(
                    "prf",
                    JSONObject().put("eval", JSONObject().put("first", saltB64Url)),
                ),
            )
        }.toString()

    private fun base64url(data: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    private fun base64urlDecode(s: String): ByteArray? =
        runCatching { Base64.getUrlDecoder().decode(s) }.getOrNull()
}
