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
identifies an independent view: summary, compact, or metrics; optional metric IDs;
briefing, menu bar, and widget visibility. Multiple views share one fetch. New
styles fall back to summary on old clients. The optional `usageDashboard` snapshot
field keeps older desktop/mobile protocol versions compatible.

The editor's Metrics section supports multiple selections and an All metrics
option. `metricIDs: []` means all; an absent `metricIDs` falls back to the legacy
`metricID`. New selections also store their first ID in `metricID` for older
paired clients. Summary shows up to three selected metrics, compact shows one,
and metrics style shows every selection in provider order. Summary uses a large
headline value with supporting metrics, Compact uses a short inline layout, and
Metrics uses a labeled table with percentage bars. These layouts are shared by
the SwiftUI preview and saved cards, with matching layouts on Android. Compact widget
projections show the first matching metric. The IDE tool accepts `metric_ids`
(an empty array selects all), with precedence over legacy `metric_id`.

## Card presentation and management

On macOS, clicking a briefing or menu-bar card opens its anchored detail popover.
The registered plugin supplies `@MainActor detailView(snapshot:configuration:)`.
The default view lists the complete snapshot; plugins can override it with native
charts and navigation. `LocalUsagePlugin` accepts a `details` factory so AI usage
can reuse model/provider charts and AI limits can show history, task costs, and
model estimates. Presentation code stays local and is never serialized into sync.

Each card has an edit control, and the detail popover includes **Edit view**.
Both open a dedicated full-height sheet with the appearance/visibility form on
the left and a live preview on the right. Edits are saved explicitly; Cancel
discards the draft. The preview uses the same renderer and plugin details as the
actual card, with recursive editing disabled.

**Briefing → Usage → Manage cards** opens an integration sidebar and card gallery.
Select an integration to see its views, add another view, or edit its connection.
Each view independently controls style, metric, and visibility in Briefing, the
menu bar, and widgets. Connection editing remains in its own sheet.

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
  cost. The usage scope picker supports account consumption, zone traffic,
  a Worker script, or an R2 bucket. Resource analytics use the GraphQL API:
  Workers report requests/errors; R2 reports operations and the latest sampled
  object data bytes, metadata bytes, and object count. The analytics window is
  the last 24 hours; storage samples are never summed across time. These are
  consumption metrics, not an invoice or a cost estimate. Grant Account Analytics
  read access. Associate each resource integration with an RxCode project to
  filter its cards alongside that project. Multiple resources use separate
  integrations; cross-account aggregation is not provided.
  Stored selectors are `worker:<script name>` and `r2:<bucket name>` (including
  the jurisdiction prefix when applicable). Empty selectors and bare zone IDs
  retain their existing meaning. GraphQL errors, including partial results,
  fail the refresh so the previous snapshot remains visibly stale.
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

### Completion recheck (2026-10-28)

- Implemented the previously missing Worker-script and R2-bucket collection.
- Local HTTP simulation exercised both resource fetches, HTTP 403, and a
  GraphQL partial-data error through `CloudUsagePlugin.fetch`; all passed.
  Source-derived synthetic fixtures are not provider billing evidence.
- The running workspace's `ide__usage_cards` response contained only AI usage
  and AI limits integrations. No cloud provider connection was configured there,
  so OAuth consent/refresh and dashboard-to-provider billing reconciliation
  remain pending provider setup in the integration sheet.
- Device discovery found a connected physical iPhone and no attached Android
  device. Discovery alone does not prove pairing, mobile delivery, background
  APNs updates, or home-screen widget rendering. Those acceptance checks remain
  pending, and the overall task must not be marked fully verified yet.

For live acceptance, connect Vercel and Cloudflare with registered public OAuth
clients and Neon/Turso with management API keys in the integration sheet. Check
initial fetch and expired-token refresh, then compare each resource and time
window with its provider dashboard/export. Pair the intended mobile clients;
confirm the same metric, project, timestamp, and style after a Mac card edit,
then verify the Usage integrations widget in foreground and background. Confirm
the old workspace's cards disappear when changing desktops. Record actual
device/provider observations separately from fixture results; never record keys.

Run the repeatable local HTTP checks using
`postman/simulations/cloudflare-usage.context.md`.

Provider references:
- https://vercel.com/docs/rest-api/billing/list-focus-billing-charges
- https://vercel.com/docs/sign-in-with-vercel/scopes-and-permissions
- https://neon.com/docs/guides/consumption-metrics
- https://docs.turso.tech/api-reference/organizations/usage
- https://docs.turso.tech/api-reference/databases/usage
- https://developers.cloudflare.com/fundamentals/oauth/integrate-with-cloudflare/
- https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/configuration/observability/
- https://developers.cloudflare.com/r2/platform/metrics-analytics/
