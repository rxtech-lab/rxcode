# ACP account usage simulation

Runs the native `ACPUsageAPI.fetch` over local HTTP with synthetic responses for
OpenCode Go usage and Antigravity quota summaries. It checks methods, paths,
headers, percent conversion, and HTTP 401/403 handling. No real credential is used.

```sh
postman simulation run postman/simulations/acp-usage.sim.yaml --port 4921 --no-history --output ndjson
RXCODE_ACP_USAGE_SIMULATION_URL=http://127.0.0.1:4921/usage swift test --package-path Packages --filter 'ACPUsageReportTests|UsagePluginTests'
```

Stop the server with Ctrl-C. The mock is local and has not been published; the
owner-workspace mock search was skipped because no owning workspace is linked.

Observed 2026-10-28: all six HTTP requests passed (success, 401, and 403 per
provider), alongside parser/request-contract tests. This does not verify actual
subscription eligibility, Keychain consent, installed-client credential loading,
provider quota accuracy, UI interaction, or mobile/widget delivery.

Contract references:
- OpenCode endpoint and migration: https://github.com/anomalyco/opencode/issues/52227
- OpenCode Go response windows and limitations: https://github.com/anomalyco/opencode/issues/44189
- Antigravity CLI authentication: https://github.com/google-antigravity/antigravity-cli
- Antigravity quota response adapter: https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift
