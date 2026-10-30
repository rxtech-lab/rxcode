# Cloudflare resource usage simulation

## Purpose

Runs the native `CloudUsagePlugin.fetch` against the HTTP contract in
`postman/mocks/cloudflare-usage/default.js`, using Cloudflare's documented
Workers and R2 GraphQL query shapes (links in `docs/usage-plugins.md`).
The `/oauth-test/{scenario}` routes also exercise native usage token refresh
and account discovery with synthetic OAuth credentials.

## Execution

From the repository root, start:

```sh
postman simulation run postman/simulations/cloudflare-usage.sim.yaml --port 4917 --no-history --output ndjson
```

In another terminal:

```sh
RXCODE_USAGE_SIMULATION_URL=http://127.0.0.1:4917/cloudflare/client/v4/graphql swift test --package-path Packages --filter 'CloudflareResourceUsageTests|UsagePluginTests|UsageDashboardSyncTests'
```

For OAuth refresh and account discovery:

```sh
TEST_RUNNER_CLOUDFLARE_USAGE_SIMULATION_URL=http://127.0.0.1:4917/cloudflare xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug -destination 'platform=macOS' -only-testing:RxCodeTests/MCPOAuthTests/testCloudflareUsageRefreshOverHTTP test
```

Stop the simulation with Ctrl-C. No real credential is used or required.

## Assumptions

- Synthetic values follow official query shapes; they do not establish live
  permissions, dataset eligibility, sampling accuracy, or OAuth behavior
  (reasoned 2026-10-28, handler and provider documentation). OAuth routes assume
  RFC 6749 refresh grants and rotation; they do not prove live Cloudflare grants
  or recovery of the user's saved session (2026-10-30).
- The Postman CLI was signed out, so an owner-workspace mock search was skipped
  (observed 2026-10-28). This mock is local and has not been published.

## Observations

<!-- begin:observations -->
2026-10-30: the sole Cloudflare member served all seven OAuth scenarios. The
native test passed over HTTP: expiry and 401 refresh, preserved/rotated refresh
tokens, no retry on 403, one retry on repeated 401, invalid-grant failure, and
20 concurrent callers sharing one rotation. Live Cloudflare remains unverified.
2026-10-28: the sole Cloudflare member served both resource requests and both
failure cases. The native tests passed over real local HTTP. A partial GraphQL
response with HTTP 200 was rejected, as was HTTP 403.
<!-- end:observations -->

## What didn't work

- 2026-10-30: Xcode test runners require the `TEST_RUNNER_` environment prefix.
  Fixture `pm.state` reads/writes must be awaited; missing awaits returned empty
  stats and then killed the mock with a 502. Corrected before the passing run.

- CLI 1.75.0 requires the simulation member path to name `config.yaml`, not
  its containing directory (observed 2026-10-28).
- The restricted execution sandbox returned `listen EPERM`; the local server
  needed permission to bind its port (observed 2026-10-28).
