# Server-evaluated Swift board filters

Status: server implementation and Mac publication flow are implemented locally. Swift 6.4.1 builds the starter filter, and its WASM output runs locally under the server Wasmtime limits. Production deployment and mobile server-result consumption are not verified as complete. The compiler is now downloaded on demand rather than embedded in the app. See `docs/features/swift-filter-publication.md` for Mac setup and verification.

## Required behavior

- Swift remains the filter authoring language on macOS.
- Compile the existing JSON stdin/stdout harness to WASI WebAssembly; store artifacts in server-managed S3.
- The server evaluates both structured saved-view filters and optional Swift/WASM filters.
- iOS displays server-selected tasks and stories, with no local filter evaluation or fallback.
- iOS cannot create, replace, or remove Swift filter code. Standard view settings remain editable through their existing sheet.

## Existing integration points

- `TaskFilterScript.harness(userScript:)`: Foundation Codable records and two predicate functions.
- `TaskFilterScriptEvaluator`: current native compiler and execution service.
- `CloudSavedViews`: account-scoped saved settings with revision-based compare-and-swap.
- github-pm `board-views` API: currently stores settings only.
- `MobileTaskBoardView`: currently evaluates structured filters and keyword search locally.
- `MobileTasksDashboardView`: preview cards also need server-selected results.
- Mobile supports both cloud and Mac-only boards; Mac-only board handling needs an explicit policy.

## Proposed contract

Preserve the existing settings API. Add a separate artifact publication API and a view-results API.

Artifact publication binds a WASM module to authenticated account, project, view ID, harness ABI version, and source SHA-256. Use server-generated storage keys; never execute a caller-supplied S3 key or URL. Activate an artifact only after validation and a matching view revision. A source change invalidates the prior artifact.

The results API returns the canonical view revision, board revision, generation time, selected task/story records, and visible columns. Search terms are request parameters evaluated by the server. Task/story references use server IDs rather than device-local UUIDs. Include results for the implicit default view when no views are saved.

Apply structured filters and Swift predicates as an intersection. Preserve existing story rollup, tag, empty-version, milestone, status, and story-panel semantics. Compute story rollups from the complete authorized board before filtering.

Compilation or evaluation failures are explicit errors, never an unfiltered success. Mobile may retain a clearly marked last successful server snapshot but must not apply local predicates to produce fresh results. Account/project/view/search changes must invalidate pending responses.

## Execution

Use an isolated WASI runtime with memory, execution-time/fuel, input, and output bounds. Expose stdin/stdout only; no network, secrets, host filesystem, or inherited environment. Validate returned IDs against the authorized input board. Store modules privately in S3, separate from publicly downloadable release assets.

## Synchronization and UI

Mac saves source and publishes compiled artifacts with a visible publishing status; errors leave the editable draft intact. All create/update/delete actions retain dedicated sheets and action-status overlays. Mobile preserves the latest server Swift source when saving standard view settings, including after conflict resolution; stale drafts must never overwrite newer Swift code. Show Swift filtering as read-only in the mobile editor.

Refresh server results after relevant task, story, saved-view, or artifact changes. Revision checks prevent mismatched board/results pairs. Desktop-to-mobile sync must carry server results, not substitute desktop-local evaluation.

## Verification

- Compile the actual starter Swift harness to WASM and run it using the server runtime.
- Verify standard and Swift filters against identical boards, including stories and custom columns.
- Exercise authorization, stale revisions, artifact/source mismatch, malformed modules, runaway modules, and output limits.
- Verify mobile never calls local predicates for board, dashboard, or search results.
- Verify stale mobile settings cannot overwrite Swift source.
- Run package tests, focused app tests, server tests, macOS build, and iOS build.
- Keep local, simulated S3, live S3, and deployed verification distinct.
