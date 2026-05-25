package app.rxlab.rxcode.identity

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.rxlab.rxcode.crypto.Hex
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom

/**
 * Mobile device identity: a stable X25519 keypair persisted in Jetpack Security
 * `EncryptedSharedPreferences` (AES-256-GCM via Android Keystore).
 *
 * Mirrors `Packages/Sources/RxCodeSync/Crypto/DeviceIdentity.swift` — the
 * public key (hex) is what's sent to the desktop during pairing.
 */
class DeviceIdentity private constructor(
    val privateKey: X25519PrivateKeyParameters,
    val publicKey: X25519PublicKeyParameters,
) {
    val publicKeyHex: String = Hex.encode(publicKey.encoded)

    companion object {
        private const val PREFS = "rxcode.device-identity"
        private const val KEY_PRIVATE = "x25519-private-key"

        fun loadOrCreate(context: Context): DeviceIdentity {
            val masterKey = MasterKey.Builder(context.applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                context.applicationContext,
                PREFS,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )

            val existing = prefs.getString(KEY_PRIVATE, null)
            val privBytes: ByteArray = if (existing != null) {
                Hex.decode(existing) ?: generate().also { prefs.edit().putString(KEY_PRIVATE, Hex.encode(it)).apply() }
            } else {
                val fresh = generate()
                prefs.edit().putString(KEY_PRIVATE, Hex.encode(fresh)).apply()
                fresh
            }
            val priv = X25519PrivateKeyParameters(privBytes, 0)
            return DeviceIdentity(priv, priv.generatePublicKey())
        }

        private fun generate(): ByteArray {
            val bytes = ByteArray(32)
            SecureRandom().nextBytes(bytes)
            return bytes
        }
    }
}
