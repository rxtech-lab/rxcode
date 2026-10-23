# Flowcy mobile production integration

This implementation is local and has not been deployed or released. The preview on `new-mobile` remains a design reference; its sample services and simulated success UI are not linked into production.

## Runtime

- Real RxLab account sign-in, session restoration and expiry lead to Projects without desktop pairing.
- Projects use the existing cloud boards, task/story editors, permission checks and direct CRUD transport. Project creation has a dedicated sheet.
- Root tabs are Projects, Features, Settings and Agent. Agent uses the prominent role on iOS 27 and a regular tab on iOS 26.
- Docs, Releases, CI/Dependency Updates, Secrets, Automation and Repository Setup reuse existing native views and typed services through `FlowcyDirectService`. Secrets remain encrypted/decrypted on the phone using its passkey vault.
- Sessions, Issues, Pull Requests, Actions, Notifications, Webhooks and Billing have account-authenticated resource reads with loading, empty, retry and cursor pagination. Session details load the account-owned message history and render it as Markdown. Webhooks have dedicated create/edit sheets and native delete confirmation; billing opens the authenticated management portal in its own sheet. General includes a persisted system/light/dark appearance choice.
- The remote toolbar menu opens real pairing or an existing paired Mac in the existing workspace. Its Flowcy return button restores cloud task routing. The remote settings no longer duplicate Flowcy account/settings navigation. Pairing records and sync payload formats are unchanged. Notification deep links and pending remote permission requests can open the remote workspace.

## Agent and MCP

The app performs model orchestration through `POST /api/v1/agent/chat`, added locally in the sibling `github-pm` checkout. It uses that service's dedicated `FLOWCY_CHAT_MODEL` (no `MODEL_NAME` fallback) and gateway credentials, account authentication, atomic RxSubscription AI allowance admission and Redis rate limiting. Standalone chat fails closed when `BILLING_PROVIDER=rxsubscription` and its account meter are not configured; legacy billing only meters installation-bound sessions. No model picker is exposed; there is no partial hard-coded Claude/Codex/ACP catalog.

Each NDJSON model turn yields text and tool calls. The phone executes only discovered MCP tools, obtains native consent for writes, sends actual results back into the next model turn, and refreshes cloud boards after successful writes. Unknown tools require consent. Tool `isError` responses remain errors in the result sent to the model. Retrying a prompt after a submitted write is blocked to avoid replaying that write. Cancellation does not undo a write already accepted by the server.

Markdown uses the existing `MarkdownContentView`. The latest conversation is persisted per account in Application Support with complete file protection, restored across launches, and removed from memory on account change. New Chat resets that conversation; a multi-conversation history browser is not included.

Tools now use `POST /api/v1/agent/tools` with the same RxAuth token as Projects and Features.
The backend reuses its MCP registry and resource ownership checks. No separate MCP OAuth
sign-in is required in the mobile app; public MCP OAuth remains available for other clients.
The app loads tools automatically on the first prompt or when opening the tools sheet.
A 401 retries once with a refreshed account token. Feature rejection after successful token
refresh displays a feature error and does not clear the account session.

Projects retain the original task dashboard in a `NavigationStack`: full-height project
cards on iPad and at regular widths (including open Duo), and a project list at compact
phone widths. Selecting a project opens its original task board without a split sidebar.
Long-press a project title to drag its card onto another card. Project Cards opens a
dedicated sheet with reorder handles and Hide/Show controls. Each wide card also has a
Hide action in its menu, with an Undo overlay. Order and visibility persist on the device;
hiding never deletes the underlying project or tasks.
Features and Settings use `NavigationSplitView` with selection-backed sidebars and
independent detail navigation. SwiftUI collapses these into a stack at compact widths.
The agent composer uses `safeAreaBar` and
`glassEffect` with a rounded, inset surface above the message scroll view.

Design references: [Apple NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Verification evidence

### Project card controls follow-up (2026-10-23)

- Replaced the dashboard's Edit button with a Project Cards sheet. Card titles support
  direct dragging; compact rows use native list reordering. Hide/Show preferences and
  card ordering persist locally, with haptics and status overlays.
- The project-card UI regression passed in wide and compact Duo layouts: drag, relaunch
  to verify order, hide all, relaunch to verify visibility, restore, and open a board.
  The final compact run used an isolated committed snapshot with these changes because
  concurrent task-form edits temporarily blocked the shared checkout's build.

### Original task layout and initial loading follow-up (2026-10-23)

- Restored the original task dashboard and board navigation; only Features and Settings
  retain split navigation. The iOS Simulator Debug build passed.
- Cloud project discovery no longer changes its own load task's identity. Project loads
  propagate their own errors, cancellation does not populate shared error state, and
  only the latest dashboard load updates its error/loading presentation.
- All 26 mobile integration tests passed, including four new regressions for initial
  discovery, overlapping refresh cancellation, board cancellation, and server-error
  recovery. The local Postman simulation recorded project/board requests and the
  injected 503 followed by successful requests. Production startup remains unverified.

### Adaptive navigation and shared-token follow-up (2026-10-23)

- Final iOS Simulator Debug build passed; 22 focused integration tests passed against
  the local Postman simulation. Captured HTTP traffic includes native tool discovery,
  calls, model turns, token refresh, repeated feature rejection, and notification operations.
- 33 focused github-pm tests, TypeScript checking, and changed-file ESLint passed.
  Backend tests exercise the actual MCP registry, account admission, cross-account project
  rejection, the dedicated chat model setting, and the existing public OAuth endpoint.
- The Duo UI walkthrough passed. Direct Device Hub inspection verified the floating
  composer, Projects/Features/Settings split views, and folding into compact navigation.
  Xcode screenshot attachments were black on this runtime; direct simulator captures
  are saved in `flowcy-mobile-fixes-screenshots/` instead.
- A final toolbar refinement uses the root size class because sidebar columns report
  compact width even when the app is wide. Direct inspection confirmed the wide layout
  has one remote menu and a fully visible Projects title.
- Authenticated production calls and iPad/physical-device behavior remain unverified.
  This run did not deploy or release either project.


### Local

- iOS Simulator Debug build passed on iPhone Duo / iOS 27.1.
- Backend TypeScript checking passed in an isolated source snapshot; focused ESLint passed in the actual sibling checkout.
- 34 focused backend tests passed in `github-pm`, covering native account admission, denied scoped API tokens, model text/tool streaming, allowance failure, non-successful model errors, webhook ownership/validation and signing-secret redaction, and failure when standalone model metering is not configured.
- iPhone production navigation walkthrough and the existing paired-workspace launch regression test passed: cloud dashboard without pairing, Features, Settings, prominent Agent composer, disconnected tools sheet, and real pairing sheet presentation. Screenshots are in `flowcy-mobile-production-screenshots/`. The account/project data in these screenshots is a Debug-only test fixture, not a live account.
- The first walkthrough found a tools-sheet environment injection crash. The fix is included and the repeated walkthrough passed.

### Simulation

Run the HTTP dependency first:

```sh
postman simulation run postman/simulations/flowcy-mobile.sim.yaml --port 4922 --output ndjson
```

Then run:

```sh
xcodebuild -project RxCode.xcodeproj -scheme RxCodeMobile \
  -testPlan MobileFlowcyIntegrationTestPlan \
  -destination 'platform=iOS Simulator,name=iPhone Duo' test
```

If port 4922 is already in use, run the simulation on another port and update
`FLOWCY_SIMULATION_BASE_URL` in `MobileFlowcyIntegrationTestPlan.xctestplan` to match.

The dedicated plan enables `FLOWCY_SIMULATION=1`; ordinary unit tests skip the HTTP-dependent cases. The tests run the actual Swift HTTP client against the local Postman server. The simulation is authored from the inspected backend contracts and was not retrieved from a published owner workspace.

12 focused tests passed for MCP discovery/SSE responses/calls/permission and tool errors, account token refresh/expiry, streaming, a prompt-to-tool-to-reply loop, denied mutation consent, cancellation and account isolation. Simulation traffic records confirm the MCP and chat paths were called. Simulated writes do not prove a live dashboard mutation.

### Live and device limits

- An unauthenticated live MCP initialize request returned 401 with the expected OAuth protected-resource challenge. Metadata advertised the unified endpoint and the five docs/issues/PR/actions scopes. This establishes discovery/challenge availability only.
- No authenticated live sign-in, tool execution or safe-workspace mutation was performed. No credentials were embedded, and no live task was created as a test.
- Removed existing raw access-token/JWT logging from the shared native authentication wrapper and raw refresh-token logging from the backend authentication flow.
- The new backend routes are local only. They must be reviewed and deployed separately before the production app can use those new routes. Deployment/release is not authorized by this task.
- The installed iOS 27.1 runtime lists only iPhone Duo as supported. Creating an M4 or M5 iPad under it fails with `Incompatible device`; installed iPad runtimes are iOS 18.1, below the app deployment target. iPad screenshots/layout verification remain blocked.
- Physical-device haptics, real remote pairing/reconnect/permission/sync regression checks beyond simulated workspace launch, full accessibility/Dynamic Type coverage, and iOS 26 fallback runtime behavior remain unverified.
- The live, iPad and physical-device acceptance criteria remain incomplete; no full acceptance claim is made.

## Direct account notifications

RxCode iOS now registers its APNs token directly with `PUT /api/v1/notifications/devices` after account sign-in/restoration and notification permission/token registration. This is independent of Mac pairing; the existing encrypted desktop push channel continues to receive token updates separately.

`FlowcyPushRegistration` uses a stable installation UUID, device name, `provider: apns`, and the signing environment. It serializes PUTs, token rotation, and DELETE so an in-flight registration cannot recreate a device after disconnect. Tokens stay in memory and authenticated request bodies; only the device UUID, account-owner identifier and opt-in preference are stored in defaults. Token values and notification content are not logged by the new handling.

Settings → Notifications → Notification Settings presents a dedicated sheet for connection status, authorization, retry, system notification settings and confirmed disconnect, with action overlays and haptics. Explicit retry re-registers even if the previous registration was removed from the web dashboard. Normal sign-out waits for device removal and surfaces a removal failure rather than reporting a successful disconnect. Session-expiry sign-out remains possible; an unresolved owner marker is retained, and a different account cannot overwrite it. Reauthenticate the original account to disconnect when this happens.

Plain backend payloads with `source: flowcy` open the Flowcy notification inbox, including cold-launch taps received before account restoration. Optional project/task/story IDs are resolved against freshly fetched, authorized cloud projects and boards. Unknown or inaccessible targets fail with retry UI. A Flowcy payload is never treated as a paired-desktop thread notification, and arbitrary payload URLs are ignored. Current backend pushes carry only `source`, so project/task routing is prepared for future scoped payloads.

The github-pm agent implemented Notifications → Mobile devices, safe registration metadata including `updatedAt`, confirmed disconnect, and the device picker in its send dialog. The browser/API device list does not expose APNs/FCM tokens. Existing backend migration and push-provider configuration requirements still apply; nothing was deployed or released.

Verification: 20 iOS integration tests passed, including five registration lifecycle/race/account-isolation cases, two payload-routing cases, and actual HTTP PUT/GET/DELETE via the local Postman simulation. The simulation log confirms registration, token-free listing, removal and an empty listing afterward. Independent backend verification passed 53 dashboard/API/device-service tests using Node 22.11 with ESM compatibility enabled. Physical iOS delivery, production registration, notification permission UI and backend browser appearance remain unverified. The simulator runtime/device changed during this follow-up; the run used iPhone Duo `DEBEB7E2-0F2C-4568-858E-FCBF76613586`.

Follow-up regression note: the existing paired-workspace launch test passed. The broader production Flowcy UI walkthrough failed at its Features → Sessions row assertion after concurrent split-navigation changes; it is not recorded as passing for this follow-up. Notification permission-sheet appearance and physical delivery remain unverified.

Final notification-specific verification against the latest shared workspace: iOS Debug test build passed; all 8 focused notification lifecycle/routing/HTTP tests passed in `/tmp/flowcy-push-final-tests.log`. Independent backend dashboard/API/device-service verification passed 53 tests. The local simulation server was stopped after verification.
