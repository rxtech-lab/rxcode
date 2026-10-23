# AI-assisted task and story creation

New cloud task and story forms offer **Create with AI**. A dedicated sheet collects the request, shows generation progress as an overlay, and previews the generated description using the shared Markdown renderer. **Use Draft** copies the title and description into the creation form. The user can edit and save normally; generation alone never creates an item or starts a Mac agent. Existing form selections remain intact.

The account-authenticated cloud client calls `POST /api/v1/agent/draft` with `projectId`, `kind` (`task` or `story`), and `prompt`. The github-pm backend requires `FLOWCY_AGENT_MODEL`, project ownership/membership, and account AI metering. It returns `{ title, details }`, with a Markdown description. There is no model picker for this server-configured helper. Paired-desktop task creation retains its existing agent behavior.

Cancellation dismisses the sheet and cancels its request. A session change discards a pending result. Errors use the native alert; generate, success, failure and apply interactions provide haptic feedback.

Backend API details and deployment configuration are documented in github-pm `docs/ai-project-drafts.md`. Deploy and configure that endpoint before releasing the matching client. Local fixtures and HTTP simulations are not evidence of a deployed model invocation.

Verification: github-pm passed 16 draft API tests using an in-memory database, 7 existing chat tests, 13 existing board service tests, and 2 web creation-dialog tests. TypeScript and focused ESLint checks passed. The iOS Debug test build compiled, and 2 HTTP integration tests passed against the local Postman simulation, covering both draft kinds, bearer refresh, and 400/404/502 error propagation. Model generation itself is mocked in backend tests; no authenticated production invocation was performed.

The native iPhone UI walkthrough also passed for both task and story creation: it generated a draft, opened Markdown review, applied the draft to the editable form, then cancelled without saving. Screenshots are retained in the test result bundle. Physical-device haptics, iPad layout and authenticated live generation remain unverified.

The simulator's exported screenshots were black, so the passing UI result establishes accessibility-driven interaction and draft field values; visual appearance was not independently confirmed from those captures.
