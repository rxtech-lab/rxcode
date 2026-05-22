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
- `POST /push` — desktop submits APNs pushes. The `push_type` field selects
  one of three delivery modes (defaults to `alert`):
  - **`alert`** (or omitted) — encrypted banner. Body:
    ```json
    {
      "device_token": "<hex APNs token>",
      "apns_environment": "sandbox",        // "sandbox" or "production"
      "encrypted_alert": "<base64 ciphertext>",
      "category": "permission_request",     // optional
      "collapse_id": "<id>"                  // optional
    }
    ```
    The encrypted alert blob is decrypted on-device by the iOS Notification
    Service Extension before iOS displays the banner.
  - **`liveactivity`** — ActivityKit start/update/end push. Body:
    ```json
    {
      "device_token": "<hex push-to-start or per-activity token>",
      "apns_environment": "sandbox",
      "push_type": "liveactivity",
      "apns_payload": { "aps": { "event": "update", "content-state": { … } } },
      "collapse_id": "<id>"                  // optional
    }
    ```
    The relay forwards `apns_payload` verbatim and suffixes the topic with
    `.push-type.liveactivity`. Live Activity content-state is **not** E2E
    encrypted — ActivityKit consumes it directly.
  - **`background`** — silent `content-available` push used to refresh the
    home-screen widget. Body is `{ "device_token", "apns_environment",
    "push_type": "background", "apns_payload" }`; the payload is forwarded
    verbatim at low priority.

  The relay signs a JWT with the configured APNs auth key and forwards the push.
  It keeps both sandbox and production APNs clients alive, then routes each
  push by `apns_environment`. If older desktop clients omit the field,
  `APNS_PRODUCTION` is used as a compatibility default.
- `GET  /healthz` — liveness probe.

## Run locally

```bash
go mod tidy
go run . -addr :8787
```

## Configuration

Every option can be set via CLI flag **or** environment variable. At startup
the binary loads `.env` (via [`godotenv`](https://github.com/joho/godotenv))
from the current directory, then reads the process environment, then applies
any explicit CLI flags. So precedence is: flag > env > `.env` file.

Override the env file path with `RELAY_ENV_FILE=/path/to/file go run .`. A
missing file is non-fatal — the relay just uses whatever's in the process env.


| Flag                | Env var            | Purpose                                              |
| ------------------- | ------------------ | ---------------------------------------------------- |
| `-addr`             | `RELAY_ADDR`       | Listen address (default `:8787`).                    |
| `-apns-key`         | `APNS_KEY_PATH`    | Path to a `.p8` auth key file on disk.               |
| *(none)*            | `APNS_KEY_B64`     | `.p8` contents base64-encoded — preferred for env.   |
| `-apns-key-id`      | `APNS_KEY_ID`      | 10-char Key ID from the Apple developer portal.      |
| `-apns-team-id`     | `APNS_TEAM_ID`     | 10-char Team ID.                                     |
| `-apns-topic`       | `APNS_TOPIC`       | iOS app bundle identifier (e.g. `app.rxlab.rxcodemobile`). |
| `-apns-production`  | `APNS_PRODUCTION`  | Compatibility default when a push omits `apns_environment`. |
| `-redis-url`        | `REDIS_URL`        | Redis URL for the multi-node backplane. Empty = single-node. |

`APNS_KEY_B64` wins over `APNS_KEY_PATH` when both are set. Both standard and
URL-safe base64 are accepted, and embedded whitespace/newlines are stripped —
so `cat AuthKey.p8 | base64` works as-is.

### Run with a `.env` file

Create `relay-server/.env` (or anywhere — point to it with `RELAY_ENV_FILE`):

```dotenv
RELAY_ADDR=:8787
APNS_KEY_B64=MIGTAgEAMBM...                # base64 of your .p8 file
APNS_KEY_ID=ABCDE12345
APNS_TEAM_ID=YYYYYYYYYY
APNS_TOPIC=app.rxlab.rxcodemobile
APNS_PRODUCTION=false                    # fallback only for old desktop builds
```

Encode the `.p8` ready for the file:

```bash
make encode-key KEY=./AuthKey_ABCDE12345.p8
```

Then run:

```bash
make run-env                   # uses ./.env
make run-env ENV_FILE=staging.env
# …or directly:
go run .                       # auto-loads ./.env if present
RELAY_ENV_FILE=staging.env go run .
```

`.env` should be `.gitignore`d.

## Docker

```bash
docker build -t rxcode-relay .
docker run -p 8787:8787 \
  -e APNS_KEY_B64="$(base64 < ./AuthKey_ABCDE12345.p8 | tr -d '\n')" \
  -e APNS_KEY_ID=ABCDE12345 \
  -e APNS_TEAM_ID=YYYYYYYYYY \
  -e APNS_TOPIC=app.rxlab.rxcodemobile \
  -e APNS_PRODUCTION=true \
  rxcode-relay
```

No bind-mount needed — the key lives only in the container environment.

## APNs setup notes

- Generate a `.p8` auth key in https://developer.apple.com/account/resources/authkeys/list.
- `-apns-topic` must equal the iOS app's bundle identifier exactly
  (`com.idealapp.RxCode.Mobile`).
- Sandbox APNs is required for development/debug builds; production APNs is
  required for TestFlight/App Store builds. The mobile app reports this as
  `sandbox` or `production`, the desktop stores it per paired device, and the
  relay chooses the matching APNs endpoint for every push.
- The auth key file is sensitive — mount it via a secrets manager / Docker
  secret in production. Never commit `.p8` files.

## Scaling — single-node vs. multi-node

The relay keeps live WebSocket connections in an in-memory map, so a naive
multi-replica deployment would drop messages: a desktop on pod A and its mobile
peer on pod B never share a connection map.

- **Single-node (default).** Leave `REDIS_URL` unset. One Go process handles
  thousands of WebSocket connections comfortably. Routing is purely in-memory;
  a recipient that isn't connected gets a `delivery_failed` notice to the
  sender. Run exactly **1 replica**.
- **Multi-node.** Set `REDIS_URL`. The relay uses Redis as a pub/sub backplane:
  an envelope whose recipient isn't on the local pod is published to the
  `relay:route` channel, and the pod holding that connection delivers it.
  Per-pubkey presence keys (`relay:presence:*`, TTL-refreshed on every ping)
  keep the `delivery_failed` notice accurate cluster-wide. Scale to any replica
  count — no sticky sessions required.

`/healthz` reports the active mode (`"mode": "single-node" | "multi-node"`).

## Kubernetes

Manifests for a multi-replica deployment live in [`k8s/`](./k8s/) — Deployment
(2 replicas), Service, Ingress (WebSocket-friendly timeouts), HPA, and a
PodDisruptionBudget. They wire `REDIS_URL` to the cluster-level Redis so the
backplane is on by default. See [`k8s/README.md`](./k8s/README.md).

Creating a GitHub **release** builds, pushes, and deploys the relay via the
`Deploy Relay Server` GitHub Actions workflow
(`.github/workflows/relay-deploy.yaml`). Pushes to `main` and pull requests
touching `relay-server/**` build and smoke-test the image only.

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
