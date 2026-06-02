package app.rxlab.rxcode.state

import android.content.Context
import app.rxlab.rxcode.crypto.SecretsCrypto
import app.rxlab.rxcode.crypto.SecretsKeyVault
import app.rxlab.rxcode.proto.AutopilotSecretFilePlaintext
import app.rxlab.rxcode.proto.CreateEnvironmentBody
import app.rxlab.rxcode.proto.SecretsBundle
import app.rxlab.rxcode.proto.SecretsEnvironment
import app.rxlab.rxcode.proto.SecretsFileMeta
import app.rxlab.rxcode.proto.UpsertFileBody
import org.bouncycastle.crypto.params.ECPrivateKeyParameters

/**
 * Orchestrates on-device secrets crypto with the relay-only [AutopilotService].
 * Mirrors the secrets section of `MobileAppState+Autopilot.swift`: the desktop
 * relays opaque ciphertext, while the phone derives the KEK from its passkey
 * ([SecretsKeyVault]) and performs all encryption/decryption locally — plaintext
 * never crosses the relay.
 */
class SecretsManager(
    private val service: AutopilotService,
    private val vault: SecretsKeyVault = SecretsKeyVault(),
) {
    suspend fun enrollmentStatus(): Boolean = service.secretsEnrollmentStatus()

    suspend fun listEnvironments(repo: String): List<SecretsEnvironment> =
        service.listSecretEnvironments(repo)

    /** Builds the owner environment key on-device, then asks the desktop to POST it. */
    suspend fun createEnvironment(context: Context, repo: String, name: String) {
        val kek = vault.kek(context, System.currentTimeMillis())
        val (body, _) = SecretsCrypto.buildOwnerEnvironmentKey(kek)
        service.createSecretEnvironment(repo, CreateEnvironmentBody(name, body))
    }

    suspend fun deleteEnvironment(repo: String, envId: String) =
        service.deleteSecretEnvironment(repo, envId)

    suspend fun listFiles(repo: String, envId: String): List<SecretsFileMeta> =
        service.listSecretFiles(repo, envId)

    suspend fun environmentPlaintext(
        context: Context,
        repo: String,
        envId: String,
    ): List<AutopilotSecretFilePlaintext> {
        val (dek, bundle) = resolveDEK(context, repo, envId)
        return bundle.files.map {
            AutopilotSecretFilePlaintext(it.filename, SecretsCrypto.decryptFile(it.ciphertext, it.iv, dek))
        }
    }

    suspend fun upsertFile(
        context: Context,
        repo: String,
        envId: String,
        filename: String,
        content: String,
    ) {
        val (dek, _) = resolveDEK(context, repo, envId)
        val (ciphertext, iv, size) = SecretsCrypto.encryptFile(content, dek)
        service.upsertSecretFile(repo, envId, UpsertFileBody(filename, ciphertext, iv, size))
    }

    suspend fun deleteFile(repo: String, envId: String, fileId: String) =
        service.deleteSecretFile(repo, envId, fileId)

    fun clearKek() = vault.clear()

    /**
     * Resolves the environment DEK on-device: derive the KEK from the passkey
     * and unwrap the DEK (unwrapping the user's private key first for
     * HPKE-shared environments).
     */
    private suspend fun resolveDEK(
        context: Context,
        repo: String,
        envId: String,
    ): Pair<ByteArray, SecretsBundle> {
        val kek = vault.kek(context, System.currentTimeMillis())
        val bundle = service.secretsBundle(repo, envId)
        var userPrivateKey: ECPrivateKeyParameters? = null
        if (bundle.environmentKey.wrapMode == "hpke") {
            userPrivateKey = SecretsCrypto.unwrapUserPrivateKey(service.secretsUserKey(), kek)
        }
        val dek = SecretsCrypto.unwrapDEK(bundle.environmentKey, kek, userPrivateKey)
        return dek to bundle
    }
}
