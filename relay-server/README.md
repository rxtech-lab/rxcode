# rxcode-relay

Stateless WebSocket relay + APNs forwarder for the RxCode desktop ↔ mobile sync channel.

The relay never decrypts payloads. All sync messages are E2E encrypted between
device pairs using Curve25519 + ChaCha20-Poly1305; the relay only sees opaque
envelopes (`{v, to, from, nonce, ct}`) and a destination pubkey.

## Endpoints

- `GET  /ws?pubkey=<64-hex>` — upgrade to WebSocket. The connecting client
  claims the pubkey; the relay does not verify ownership because the E2E layer
  already prevents reading or forging messages. Drop-on-offline: if the
  recipient pubkey isn't currently connected, the envelope is dropped and the
  sender receives a `delivery_failed` notice.
- `POST /push` — desktop submits APNs pushes. Body:
  ```json
  {
    "device_token": "<hex APNs token>",
    "encrypted_alert": "<base64 ciphertext>",
    "category": "permission_request",     // optional
    "collapse_id": "<id>"                  // optional
  }
  ```
  The relay signs a JWT with the configured APNs auth key and forwards the
  push. The encrypted alert blob is decrypted on-device by the iOS
  Notification Service Extension before iOS displays the banner.
- `GET  /healthz` — liveness probe.

## Run locally

```bash
go mod tidy
go run . -addr :8787
```

To also enable APNs:

```bash
go run . \
  -addr :8787 \
  -apns-key ./AuthKey_ABCDE12345.p8 \
  -apns-key-id ABCDE12345 \
  -apns-team-id YYYYYYYYYY \
  -apns-topic com.idealapp.RxCode.Mobile \
  -apns-production=false
```

## Docker

```bash
docker build -t rxcode-relay .
docker run -p 8787:8787 \
  -v $(pwd)/AuthKey_ABCDE12345.p8:/keys/apns.p8:ro \
  rxcode-relay \
  -addr :8787 \
  -apns-key /keys/apns.p8 \
  -apns-key-id ABCDE12345 \
  -apns-team-id YYYYYYYYYY \
  -apns-topic com.idealapp.RxCode.Mobile \
  -apns-production=true
```

## APNs setup notes

- Generate a `.p8` auth key in https://developer.apple.com/account/resources/authkeys/list.
- `-apns-topic` must equal the iOS app's bundle identifier exactly
  (`com.idealapp.RxCode.Mobile`).
- Sandbox (`-apns-production=false`) is required for `xcrun simctl push` and
  development builds; production builds and TestFlight require
  `-apns-production=true`.
- The auth key file is sensitive — mount it via a secrets manager / Docker
  secret in production. Never commit `.p8` files.

## Wire envelope

```json
{
  "v": 1,
  "to":    "<64-hex Curve25519 pubkey>",
  "from":  "<64-hex Curve25519 pubkey>",
  "nonce": "<base64 12-byte nonce>",
  "ct":    "<base64 ChaCha20-Poly1305 ciphertext>"
}
```

Plaintext payload schema lives in the `RxCodeSync` Swift package
(`Sources/RxCodeSync/Protocol/Payload.swift`).
