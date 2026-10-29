# Cloudflare account discovery simulation

Created 2026-10-29 from the public [List Memberships contract](https://developers.cloudflare.com/api/resources/memberships/methods/list/) and [Billable Usage v1 contract](https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/get_account_usage_v1/).

## Purpose

Runs `CloudflareAccounts.list` and account billing `CloudUsagePlugin.fetch` over
real local HTTP to verify the billable-usage route, current-period requests,
FOCUS consumption aggregation, billing-specific 403 errors, pagination,
deduplication, active membership filtering, and permission/malformed-response errors.

## Execution

```sh
postman simulation run postman/simulations/cloudflare-accounts.sim.yaml --port 4923 --no-history --output ndjson
RXCODE_CLOUDFLARE_SIMULATION_URL=http://127.0.0.1:4923/cloudflare swift test --package-path Packages --filter CloudflareAccountsTests
```

Use the listening event's address if the port differs. Stop with Ctrl-C.

## Assumptions

- Synthetic account memberships follow the documented response schema. Owner mock
  lookup was skipped because this repository has no linked owning Postman workspace.
- Live OAuth grants, Keychain access, account resource restrictions, and native
  picker interaction require separate acceptance with Cloudflare.

## Observations

<!-- begin:observations -->
2026-10-29: 18 focused tests passed. The sole member served three billing calls
(success, HTTP 403, malformed data) and four membership calls. No member stayed
silent. These fixtures do not prove that an OAuth token can access live billing.
2026-10-29: The focused HTTP test passed. The sole member served two paginated
success requests, one HTTP 403, and one malformed response. No member stayed silent.
<!-- end:observations -->

## What didn't work

2026-10-29: Local port binding required execution outside the workspace sandbox
(`listen EPERM`).
