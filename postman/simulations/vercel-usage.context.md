# Vercel usage simulation

Created 2026-10-29 from Vercel's public billing and AI Gateway contracts.

## Purpose

Runs `CloudUsagePlugin.fetch` over real local HTTP, verifying billable totals,
project filtering, separate billing/Gateway authentication, and unavailable
credits without discarding successful billing data.

## Execution

```sh
postman simulation run postman/simulations/vercel-usage.sim.yaml --port 4922 --no-history --output ndjson
RXCODE_VERCEL_SIMULATION_URL=http://127.0.0.1:4922/usage swift test --package-path Packages --filter 'UsagePluginTests|VercelUsageTests'
```

Use the listening event's address if the bound port differs. Stop with Ctrl-C.

## Assumptions

- Synthetic fixtures follow [billing charges](https://vercel.com/docs/rest-api/billing/list-focus-billing-charges)
  and [Gateway credits](https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance).
  Owner mock lookup was skipped; no owning Postman workspace is linked here.
- Billing is a rolling 30-day export; Gateway balance is team-wide and current.
  Neither fixture proves dashboard billing-cycle or included-credit reconciliation.
- Live credentials, Keychain access, native UI, mobile, and widgets remain unverified.

## Observations

<!-- begin:observations -->
2026-10-29: 13 focused tests passed. The sole member served four billing requests
and three Gateway requests (success, HTTP 403, malformed response). Missing-key
case made no Gateway request. No member stayed silent. macOS Debug build passed.
<!-- end:observations -->

## What didn't work

- Local port binding and Xcode caches required execution outside the workspace sandbox.
