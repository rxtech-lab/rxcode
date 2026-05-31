---
slug: api/relay-server
title: Relay Server API
description: HTTP and WebSocket API of the RxCode mobile-sync relay (rxcode-relay).
---

# Relay Server API

`rxcode-relay` (`relay-server/`) is a stateless Go WebSocket relay and APNs/FCM
forwarder for the RxCode desktop ↔ mobile sync channel. It never decrypts
payloads: all sync messages are E2E encrypted between device pairs using
Curve25519 + ChaCha20-Poly1305, and the relay only sees opaque envelopes
(`{v, to, from, nonce, ct}`) plus a destination pubkey.

```bash
# Run locally
go mod tidy
go run . -addr :8787
```

## Endpoints

### `GET /ws?pubkey=<64-hex>`

Upgrades to a WebSocket. The connecting client claims the `pubkey`; the relay
does not verify ownership because the E2E layer already prevents reading or
forging messages. **Drop-on-offline:** if the recipient pubkey isn't currently
connected, the envelope is dropped and the sender receives a `delivery_failed`
notice.

### `POST /push`

The desktop submits APNs or FCM pushes. The optional `provider` field selects
`"apns"` (default) or `"fcm"`. For APNs, `push_type` selects one of three
delivery modes (defaults to `alert`).

**`alert`** — encrypted banner (decrypted on-device by the iOS Notification
Service Extension):

```json
{
  "device_token": "<hex APNs token>",
  "apns_environment": "sandbox",
  "encrypted_alert": "<base64 ciphertext>",
  "category": "permission_request",
  "collapse_id": "<id>"
}
```

**`liveactivity`** — ActivityKit start/update/end push. `apns_payload` is
forwarded verbatim and the topic is suffixed with `.push-type.liveactivity`.
Live Activity content-state is **not** E2E encrypted:

```json
{
  "device_token": "<hex push-to-start or per-activity token>",
  "apns_environment": "sandbox",
  "push_type": "liveactivity",
  "apns_payload": { "aps": { "event": "update", "content-state": {} } },
  "collapse_id": "<id>"
}
```

**`background`** — silent `content-available` push to refresh the home-screen
widget. Body is `{ device_token, apns_environment, push_type: "background",
apns_payload }`, forwarded verbatim at low priority.

**FCM alert** — encrypted Android banner sent as an FCM HTTP v1 data message;
the Android app decrypts `enc` locally:

```json
{
  "provider": "fcm",
  "device_token": "<FCM registration token>",
  "encrypted_alert": "<base64 ciphertext>",
  "category": "permission_request",
  "collapse_id": "<id>"
}
```

The relay signs a JWT with the configured APNs auth key, keeps both sandbox and
production APNs clients alive, and routes each push by `apns_environment`. If
older desktop clients omit the field, `APNS_PRODUCTION` is used as the
compatibility default.

### `GET /healthz`

Liveness probe. Reports the active routing mode as
`"mode": "single-node" | "multi-node"`.

## Configuration

Every option is settable via CLI flag or environment variable; precedence is
**flag > env > `.env` file**.

| Flag | Env var | Purpose |
| --- | --- | --- |
| `-addr` | `RELAY_ADDR` | Listen address (default `:8787`). |
| `-apns-key` | `APNS_KEY_PATH` | Path to a `.p8` auth key file. |
| *(none)* | `APNS_KEY_B64` | `.p8` contents base64-encoded — preferred for env. Wins over `APNS_KEY_PATH`. |
| `-apns-key-id` | `APNS_KEY_ID` | 10-char Key ID from the Apple developer portal. |
| `-apns-team-id` | `APNS_TEAM_ID` | 10-char Team ID. |
| `-apns-topic` | `APNS_TOPIC` | iOS app bundle identifier (e.g. `app.rxlab.rxcodemobile`). |
| `-apns-production` | `APNS_PRODUCTION` | Compatibility default when a push omits `apns_environment`. |
| `-fcm-project-id` | `FCM_PROJECT_ID` | Firebase project ID (optional if present in the service-account JSON). |
| `-fcm-service-account` | `GOOGLE_APPLICATION_CREDENTIALS` | Path to Firebase service-account JSON. |
| *(none)* | `FCM_SERVICE_ACCOUNT_JSON` | Raw Firebase service-account JSON. |
| *(none)* | `FCM_SERVICE_ACCOUNT_B64` | Base64-encoded service-account JSON, preferred for container secrets. |
| `-redis-url` | `REDIS_URL` | Redis URL for the multi-node backplane. Empty = single-node. |

## Scaling

- **Single-node (default).** Leave `REDIS_URL` unset and run exactly 1 replica;
  routing is in-memory and offline recipients yield a `delivery_failed` notice.
- **Multi-node.** Set `REDIS_URL`. Envelopes whose recipient isn't on the local
  pod are published to the `relay:route` channel; per-pubkey presence keys
  (`relay:presence:*`) keep `delivery_failed` accurate cluster-wide. Scale to
  any replica count — no sticky sessions required.

Kubernetes manifests for a multi-replica deployment live in `relay-server/k8s/`.

See [Architecture Overview](../architecture/overview) for where the relay fits
in the overall system.
