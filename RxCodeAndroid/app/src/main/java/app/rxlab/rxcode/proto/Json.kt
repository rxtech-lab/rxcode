package app.rxlab.rxcode.proto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import java.util.UUID

/** Shared JSON config: Swift's default JSONEncoder/JSONDecoder behavior. */
val RxJson: Json = Json {
    ignoreUnknownKeys = true
    // Swift's JSONEncoder always emits every stored property, and its JSONDecoder
    // requires every non-optional one. kotlinx defaults to omitting a property when
    // it equals its default value — which silently drops fields like
    // `forceRefresh = false`, causing Swift to fail decoding with keyNotFound and
    // the relay to drop the whole payload. Always encode defaults so the wire shape
    // matches what Swift's non-optional Codable structs expect.
    encodeDefaults = true
    explicitNulls = false
    isLenient = true
    coerceInputValues = true
}

/**
 * Mirrors Foundation's default `Date` encoding: seconds (Double) since the
 * Cocoa reference date (2001-01-01 00:00:00 UTC).
 *
 * Reference date epoch (UTC seconds since 1970-01-01) = 978307200.
 */
object SwiftDateSerializer : KSerializer<Instant> {
    private const val REFERENCE_EPOCH_SECONDS = 978_307_200L

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("SwiftDate", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Instant) {
        val secondsSinceReference = value.epochSecond - REFERENCE_EPOCH_SECONDS +
            value.nano / 1_000_000_000.0
        encoder.encodeDouble(secondsSinceReference)
    }

    override fun deserialize(decoder: Decoder): Instant {
        if (decoder is JsonDecoder) {
            val primitive = decoder.decodeJsonElement() as? JsonPrimitive
                ?: throw SerializationException("Expected date primitive")
            primitive.doubleOrNull?.let { return decodeCocoaReferenceDate(it) }
            primitive.contentOrNull?.let { content ->
                content.toDoubleOrNull()?.let { return decodeCocoaReferenceDate(it) }
                return Instant.parse(content)
            }
            throw SerializationException("Expected date string or number")
        }
        return decodeCocoaReferenceDate(decoder.decodeDouble())
    }

    private fun decodeCocoaReferenceDate(secondsSinceReference: Double): Instant {
        val epochSeconds = REFERENCE_EPOCH_SECONDS + secondsSinceReference.toLong()
        val nanoFraction = ((secondsSinceReference - secondsSinceReference.toLong()) * 1_000_000_000)
            .toLong().coerceAtLeast(0L)
        return Instant.ofEpochSecond(epochSeconds, nanoFraction)
    }
}

/** Swift `UUID` encodes as an uppercase hyphenated string. */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) {
        encoder.encodeString(value.toString().uppercase())
    }

    override fun deserialize(decoder: Decoder): UUID =
        UUID.fromString(decoder.decodeString())
}
