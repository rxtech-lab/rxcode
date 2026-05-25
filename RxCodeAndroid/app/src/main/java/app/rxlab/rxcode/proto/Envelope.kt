package app.rxlab.rxcode.proto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.Base64

/** Cleartext relay envelope. `ct` is opaque to the relay. */
@Serializable
data class Envelope(
    val v: Int = 1,
    val to: String,
    val from: String,
    val nonce: String,
    val ct: String,
) {
    val nonceData: ByteArray? get() = decodeB64(nonce)
    val ciphertextData: ByteArray? get() = decodeB64(ct)

    companion object {
        fun build(toHex: String, fromHex: String, nonce: ByteArray, ciphertext: ByteArray): Envelope =
            Envelope(
                v = 1,
                to = toHex,
                from = fromHex,
                nonce = Base64.getEncoder().encodeToString(nonce),
                ct = Base64.getEncoder().encodeToString(ciphertext),
            )

        private fun decodeB64(s: String): ByteArray? = try {
            Base64.getDecoder().decode(s)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

/** Sent by the relay back when the recipient is offline. */
@Serializable
data class DeliveryFailedNotice(
    val v: Int,
    val type: String,
    val to: String,
) {
    companion object {
        const val TYPE = "delivery_failed"
    }
}

@Serializable
private data class TypeOnly(@SerialName("type") val type: String? = null)

internal fun envelopeOrDeliveryFailure(raw: String): EnvelopeOrFailure? {
    val element = try {
        RxJson.parseToJsonElement(raw)
    } catch (_: Throwable) {
        return null
    }
    val type = (element as? kotlinx.serialization.json.JsonObject)
        ?.get("type")?.toString()?.trim('"')
    return when (type) {
        DeliveryFailedNotice.TYPE -> EnvelopeOrFailure.Failure(RxJson.decodeFromJsonElement(DeliveryFailedNotice.serializer(), element))
        else -> {
            val env = try {
                RxJson.decodeFromJsonElement(Envelope.serializer(), element)
            } catch (_: Throwable) {
                return null
            }
            EnvelopeOrFailure.Env(env)
        }
    }
}

internal sealed interface EnvelopeOrFailure {
    data class Env(val envelope: Envelope) : EnvelopeOrFailure
    data class Failure(val notice: DeliveryFailedNotice) : EnvelopeOrFailure
}
