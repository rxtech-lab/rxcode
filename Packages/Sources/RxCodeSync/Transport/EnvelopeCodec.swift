import Foundation
import CryptoKit
import os

/// Shared `Envelope` encode/decode used by every `Transport`.
///
/// The wire unit on all paths — relay WebSocket or direct TCP — is the identical
/// `Envelope` JSON: a `Payload` sealed for the recipient with `SessionCrypto`.
/// Factoring it here means `RelayClient` and `DirectTransport` share one
/// implementation of the crypto, so a direct link has exactly the same E2E
/// guarantee as the relay (which is explicitly untrusted).
enum EnvelopeCodec {
    private static let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "EnvelopeCodec")

    /// Result of decoding a raw inbound frame.
    enum DecodeResult {
        case inbound(TransportInbound)
        case deliveryFailed(toHex: String)
        /// Not addressed to us, malformed, or undecryptable — drop quietly.
        case drop
    }

    /// Encrypt `payload` for `recipient` and return the serialized `Envelope` JSON.
    static func encode(
        _ payload: Payload,
        from identity: DeviceIdentity,
        to recipient: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let plaintext = try JSONEncoder().encode(payload)
        let (nonce, ct) = try SessionCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: recipient
        )
        let envelope = Envelope(
            to: recipient.rawRepresentation.hexString,
            from: identity.publicKeyHex,
            nonce: nonce,
            ct: ct
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Decode a raw inbound frame: a `DeliveryFailedNotice`, an `Envelope` we can
    /// decrypt into a `Payload`, or nothing.
    static func decode(_ raw: Data, localIdentity identity: DeviceIdentity) -> DecodeResult {
        let decoder = JSONDecoder()
        if let notice = try? decoder.decode(DeliveryFailedNotice.self, from: raw),
           notice.type == "delivery_failed" {
            return .deliveryFailed(toHex: notice.to)
        }
        guard let env = try? decoder.decode(Envelope.self, from: raw) else {
            logger.warning("[Codec] dropping non-envelope message bytes=\(raw.count, privacy: .public)")
            return .drop
        }
        guard let nonce = env.nonceData,
              let ct = env.ciphertextData,
              let fromRaw = Data(hexString: env.from),
              let fromKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: fromRaw)
        else {
            logger.warning("[Codec] dropping malformed envelope from=\(String(env.from.prefix(12)), privacy: .public)")
            return .drop
        }
        do {
            let plaintext = try SessionCrypto.open(
                ciphertext: ct,
                nonce: nonce,
                recipient: identity.privateKey,
                sender: fromKey
            )
            let payload = try decoder.decode(Payload.self, from: plaintext)
            return .inbound(TransportInbound(from: fromKey, fromHex: env.from, payload: payload))
        } catch {
            // Decrypt or decode failure means the sender isn't a paired peer we
            // know how to talk to, OR the wire format drifted. Drop quietly.
            logger.warning("[Codec] dropping encrypted payload from=\(String(env.from.prefix(12)), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .drop
        }
    }
}
