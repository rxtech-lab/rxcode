# Usage integration API (v1)

Native implementations conform to `UsagePlugin` in RxCodeCore. Register them by
stable ID with `UsagePluginRegistry` during `AppState.startUsagePlugins` and add
the ID to the integration editor catalog. This is a compiled native plugin API;
it does not load executable plugins from disk or synced data.

`fetch(configuration:credential:now:)` returns `UsagePluginSnapshot`. Keep stable
metric IDs and explicit units. Do not combine currencies, treat unavailable data
as zero, or return credentials in snapshots/errors. Network collection runs in
actors. `LocalUsagePlugin` adapts existing AI collectors to the same contract.
Refresh is deduplicated and runs every 15 minutes while RxCode is running.

`UsageIntegration` identifies one account/resource connection. `UsageCardConfiguration`
identifies an independent view: summary, compact, or metrics; optional metric ID;
briefing, menu bar, and widget visibility. Multiple views share one fetch. New
styles fall back to summary on old clients. The optional `usageDashboard` snapshot
field keeps older desktop/mobile protocol versions compatible.

Configuration and last successful snapshots are stored atomically in
`usage-dashboard.json` inside the active workspace storage directory. API keys and OAuth
tokens are separate Keychain items. Each workspace owns its dashboard and optional RxCode project associations.
Only the frontmost workspace publishes mobile and widget data.

Agents use `ide__usage_cards` to read normalized data or upsert/delete card views.
Authentication is only configured in the native integration sheet. Do not edit
the JSON while RxCode is running: the in-memory state owns writes. No secret is
accepted by the agent tool or sent in mobile/widget snapshots.

## Providers

- Vercel: OAuth public PKCE client; callback `rxcode://usage-oauth`. Request
  `openid offline_access` and configure **Billing: Read Only** in the provider
  app. Vercel documents team API permissions as private beta. Uses
  `GET /v1/billing/charges`, parses JSONL, sums BilledCost by currency/service,
  and optionally filters `Tags.ProjectId`. Window: last 30 days.
- Neon: organization ID and management API key. Uses
  `/api/v2/consumption_history/v2/projects`, daily granularity, follows project
  cursors. Optional provider project ID; omitted means all projects in that
  organization (not all organizations owned by the user). Reports compute,
  root storage byte-hours, and public transfer. Plan eligibility applies.
- Turso: organization slug and platform API key (not a database auth token).
  Organization usage uses the current billing period. Optional database name
  uses `/databases/{name}/usage` over 30 days. Reads aggregate totals once.
- Cloudflare: public OAuth PKCE client and explicit scopes configured in the
  application. Account billing usage reports product consumption, not invoice
  cost. Optional zone ID selects zone request/bandwidth analytics. Workers/R2
  project-specific attribution and cross-account aggregation are not provided.
- GitHub CI: read-only Actions API token; account field is a comma-separated
  list of `owner/repo` names. Last 30 days, pull_request workflow first attempts
  only. Wait = run_started_at minus created_at. Each PR's workflow mean is
  weighted equally in repository and overall means. Excludes reruns and runs
  without a PR association/start timestamp. This is queue wait, not execution
  duration or end-to-end time until all checks pass. Pagination limits fail
  explicitly rather than showing a truncated total.
- AI usage and AI limits: existing local usage buckets and rate-limit collectors.
  Includes Claude, Codex, and recorded ACP model turns. ACP does not expose
  account limits. Detailed historical charts remain available through the AI
  card context menu. Default usage window is seven days.

## Sync and widgets

macOS sends credential-free configuration and snapshots through existing E2E
mobile snapshots. iOS and Android render the same configured views. Changes are
managed on the Mac or through the IDE tool and flow to paired clients. Android, iOS, and macOS have separate Usage integrations widgets. iOS plugin
widgets refresh after foreground snapshots and encrypted background APNs pushes.
Background pushes include at most three compact card projections to bound their
size. Android refreshes its persisted widget data on mobile snapshots and clears
it when switching desktops. WidgetKit controls Apple widget scheduling. Timestamps remain visible and data older than one hour
is marked stale.

## Verification boundary

Parser, aggregation, and sync compatibility tests use local fixtures. These do
not establish provider access, OAuth app approval, live billing accuracy,
paired-device behavior, or on-device widget behavior. Registered public OAuth
clients and account credentials are required for live verification.

Provider references:
- https://vercel.com/docs/rest-api/billing/list-focus-billing-charges
- https://vercel.com/docs/sign-in-with-vercel/scopes-and-permissions
- https://neon.com/docs/guides/consumption-metrics
- https://docs.turso.tech/api-reference/organizations/usage
- https://docs.turso.tech/api-reference/databases/usage
- https://developers.cloudflare.com/fundamentals/oauth/integrate-with-cloudflare/
