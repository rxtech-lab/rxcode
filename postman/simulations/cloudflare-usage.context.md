# Cloudflare resource usage simulation

## Purpose

Runs the native `CloudUsagePlugin.fetch` against the HTTP contract in
`postman/mocks/cloudflare-usage/default.js`, using Cloudflare's documented
Workers and R2 GraphQL query shapes (links in `docs/usage-plugins.md`).

## Execution

From the repository root, start:

```sh
postman simulation run postman/simulations/cloudflare-usage.sim.yaml --port 4917 --no-history --output ndjson
```

In another terminal:

```sh
RXCODE_USAGE_SIMULATION_URL=http://127.0.0.1:4917/cloudflare/client/v4/graphql swift test --package-path Packages --filter 'CloudflareResourceUsageTests|UsagePluginTests|UsageDashboardSyncTests'
```

Stop the simulation with Ctrl-C. No real credential is used or required.

## Assumptions

- Synthetic values follow official query shapes; they do not establish live
  permissions, dataset eligibility, sampling accuracy, or OAuth behavior
  (reasoned 2026-10-28, handler and provider documentation).
- The Postman CLI was signed out, so an owner-workspace mock search was skipped
  (observed 2026-10-28). This mock is local and has not been published.

## Observations

<!-- begin:observations -->
2026-10-28: the sole Cloudflare member served both resource requests and both
failure cases. The native tests passed over real local HTTP. A partial GraphQL
response with HTTP 200 was rejected, as was HTTP 403.
<!-- end:observations -->

## What didn't work

- CLI 1.75.0 requires the simulation member path to name `config.yaml`, not
  its containing directory (observed 2026-10-28).
- The restricted execution sandbox returned `listen EPERM`; the local server
  needed permission to bind its port (observed 2026-10-28).
