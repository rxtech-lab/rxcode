# Kubernetes Deployment — RxCode Relay

Deploys the RxCode relay server (WebSocket sync relay + APNs forwarder) as a
horizontally scalable service.

## Architecture

- **rxcode-relay** — Go relay, 2+ replicas, port 8787 (`/ws`, `/push`, `/healthz`)
- **Redis backplane** — reuses the cluster-level Redis at
  `redis://redis.redis.svc.cluster.local:6379` (namespace `redis`) for pub/sub
  routing across replicas, so desktop and mobile peers may land on different
  pods. Without `REDIS_URL` the relay runs single-node (1 replica only).

Everything lives in the `rxcode-relay` namespace.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `rxcode-relay` namespace |
| `configmap.yaml` | Non-secret config — `RELAY_ADDR`, `APNS_TOPIC`, `APNS_PRODUCTION`, `REDIS_URL` |
| `secrets.yaml` | APNs auth credentials (placeholder values — **not** in kustomization) |
| `deployment.yaml` | Relay Deployment, 2 replicas, `/healthz` probes |
| `service.yaml` | ClusterIP on port 8787 |
| `ingress.yaml` | NGINX ingress for `relay.rxlab.app` with WebSocket timeouts |
| `pdb.yaml` | PodDisruptionBudget — keeps ≥1 relay through drains/updates |
| `hpa.yaml` | HorizontalPodAutoscaler — CPU-based, 2–6 replicas (needs metrics-server) |
| `kustomization.yaml` | Kustomize orchestration |

## Prerequisites

1. Kubernetes cluster with `kubectl` access
2. NGINX Ingress Controller
3. cert-manager with a `letsencrypt-prod` cluster-issuer
4. Cluster-level Redis reachable at `redis.redis.svc.cluster.local:6379`
5. metrics-server (only required for the HPA)

## Setup

### 1. Populate secrets

Edit `secrets.yaml` with real APNs values, then apply it manually (it is
deliberately excluded from `kustomization.yaml`):

```bash
# encode the .p8 auth key
base64 < AuthKey_XXXXXXXXXX.p8 | tr -d '\n'

kubectl apply -f secrets.yaml
```

### 2. Deploy

```bash
kubectl apply -k .
```

### 3. Verify

```bash
kubectl get pods -n rxcode-relay
kubectl get svc,ingress,hpa -n rxcode-relay
```

## CI/CD

`.github/workflows/relay-deploy.yaml` deploys on every GitHub **release**:

1. Builds the relay Docker image and pushes it to
   `ghcr.io/rxtech-lab/rxcode-relay` (tags: release semver + `latest`).
2. Applies these manifests with `kubectl kustomize`, then pins the Deployment
   to the released image tag and waits for the rollout.

Pushes to `main` and pull requests touching `relay-server/**` build the image
and smoke-test `/healthz` only — no push, no deploy.

Required GitHub secret: `K8S_CONFIG_FILE_B64` (base64-encoded kubeconfig).

## Health & scaling

- `GET /healthz` returns `{"mode": "multi-node", "peers": N, ...}`.
- Replica count is safe to raise: the Redis backplane routes envelopes across
  pods, and no sticky sessions are needed. The HPA scales on CPU between 2 and
  6 replicas.
