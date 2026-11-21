# Flowcy MCP access

Story: Add ide tools for manage settings and projects. Target version: v2.0.0. Milestone: v2.

All agent backends receive `ide__flowcy_catalog`, `ide__flowcy`, `ide__get_ci_status`, and `ide__search_docs`. They use the desktop's existing signed-in account, native services, and repository/project mappings. These tools are available on session MCP listeners, not the separately configured memory-only HTTP API.

`ide__flowcy_catalog` returns an explicit allowlist and parameter schema for each operation. Pass `operation` to inspect one contract. Execute it with `ide__flowcy` using `{ "operation": "docsGetDocument", "parameters": { "repoId": "owner/repo", "docId": "design/overview" } }`. Unknown operations and extra top-level parameters are rejected; there is no arbitrary HTTP or mobile-command forwarding. Nested payloads use the same Codable request types and backend validation as the native UI.

## Capability inventory

| Native capability | MCP access |
| --- | --- |
| Signed-in account status | `accountStatus`; also works while signed out |
| GitHub App installations and accessible repositories | `installations`, `installationPrecheck`, `installGitHubAppUrl`, `repositories` (optional forced refresh), `listManagedRepos`, `cloneManagedRepo` |
| Automation preferences | `automationSchema`, `automationValues`, `automationSave` |
| Repository setup templates | `repoSetupSchema`, `repoSetupList`, `repoSetupGet`, `repoSetupCreate`, `repoSetupUpdate`, `repoSetupDelete` |
| Cloud documentation search | Existing `ide__search_docs`, now available regardless of backend native search support |
| Docs repositories and content | `docsList`, `docsAdd`, `docsDelete`, `docsListDocuments`, `docsGetDocument`, `docsVersions`, `docsVersion`, `docsUploadDocument`, `docsDeleteDocument` |
| Docs CI secret installation | `docsInstallGithubSecret` and existing `ide__setup_docs_secret`; installation happens server-side, with no token returned |
| Actual GitHub Actions progress | `ide__get_ci_status`, including workflow runs and jobs |
| CI/dependency/security update automation | `ciList`, `ciOverview`, `ciAdd`, `ciUpdateFrequency`, `ciDelete`, `ciHistory`, `ciTrigger`, `ciTriggerDependencies`, `ciListPRs`, `ciClosePR`, `ciAutomationGet`, `ciAutomationSave`, `ciDirectories` |
| Releases | `releaseList`, `releaseAdd`, `releaseDelete`, `releaseListWorkflows`, `releaseBranches`, `releaseDispatchHistory`, `releaseRescanWorkflows`, `releaseSetWorkflowSelected`, `releaseDispatch`; existing `ide__setup_release` registers/scans only |
| Pull requests | `createPullRequest` uses existing account-authorized GitHub App transport; it does not push local changes |
| Secrets metadata | `secretsEnrollmentStatus`, `secretsListEnvironments`, `secretsListFiles`, `secretsSearchFiles`, `secretsAddRepository` |
| Secrets deletion | `secretsDeleteEnvironment`, `secretsDeleteFile` |
| Secrets enrollment, environment creation, file upload/edit, local download | `secretsManage` opens the existing native manager; `secretsDownload` opens the native download/unlock flow. Credentials and passkey operations remain native |
| Release credential installation | `releaseTokenSetup` opens native release setup; `ide__setup_release` rejects legacy `release_token` input |
| Cloud project and device inventory | `cloudProjects`, `cloudProjectCreate`, `cloudDevices`, `cloudDeviceRegister` (uses this Mac's identity) |
| Cloud board and view reads | `cloudBoard`, `cloudSavedViews`; preserves cloud IDs, membership, role, and timestamps |
| Cloud board and view writes | `cloudStoryCreate/Update/Delete`, `cloudTaskCreate/Update/Delete`, `cloudSavedViewsSave`; these use cloud IDs and full native request fields. Prefer the existing IDE task/story/view tools for linked local boards, which preserve local identities and sync mappings |
| Cloud board drafting and sync | `cloudDraft`, `cloudLink`, `cloudEnable`, `cloudDisable`, `cloudSync`; link validates cloud account access and reports scheduled sync separately |
| Project UI flows and cached feature availability | `projectAutopilotStatus`, `projectSecretsSetup`, `projectDocsSetup`, `projectDocsSearch`, `projectReleaseSetup`, `projectReleaseCreate` |
| Notification quota and verified recipient management | `notificationUsage`, `trustedEmails`, `trustedEmailAdd`, `trustedEmailRemove` |
| Notification sending and attachment handling | Existing `ide__send_notification` and briefing tools; attachments keep the native presigned upload path. Sending requires an explicit user request under the existing tool policy |
| Flowcy model catalog and cloud chat | `cloudChatModels` reads the account catalog. The `cloudChat` MCP operation sends a one-shot text prompt. Interactive Flowcy project chats can run terminal commands in the active checkout through the Mac permission queue. |
| Cloud usage dashboards | Existing `ide__get_integration_usage` and `ide__usage_cards`; these are separate from live CI progress |

Mutating operations show the existing native confirmation sheet with their operation and parameters before executing. Cancellation performs no service mutation. Opening a native UI reports `awaiting_user`; it does not claim the user finished the action. Native passkey authorization and server account/repository permissions are retained. No sign-in, token refresh, or permission bypass is introduced.

## Documents and freshness

Search returns an `items` envelope with snippets, logical document IDs, repository names/IDs, indexed version, and fetch/source metadata. Search is an asynchronous semantic index and can lag uploaded content. Use `docsGetDocument` with a search hit's `docs_repository_id` as `repoId` and `doc_id` as `docId`. The full Markdown is `result.currentVersion.content`; version, source link, update, embedding status and error timestamps remain available. Standalone document repositories work via their docs repository ID. `docsVersion` fetches historical content.

Upload acceptance is not embedding completion. `projectAutopilotStatus` is explicitly cached configuration. Repository listings may use the server's 60-second cache; `repositories` supports `refresh: true`. Cloud reads carry request timestamps; server record timestamps describe the records, not the time of the tool invocation. Native sync failures are reported without claiming success.

## Live CI contract and backend dependency

`ide__get_ci_status` resolves `project_id` (or the calling chat's project) to its existing `gitHubRepo`. No caller-supplied credential or arbitrary repository is needed. It calls native `AutopilotService.ciActivity`, bypassing URLSession's local cache, against `GET /api/v1/ci-status/runs`. The backend resolves account access to the GitHub App installation before querying GitHub directly.

The existing backend implementation is in the sibling `github-pm` project, `app/api/v1/ci-status/runs/route.ts`, introduced by commit `fc96551` / PR #346. No new backend contract is invented here. Deployment of that endpoint is required and must be verified separately against the target environment.

- Default: repository workflow runs across branches, 30 per page, `page` and `hasMore` pagination.
- `workflow_id`: runs for one workflow.
- `run_id`: jobs for one run. Cannot be combined with `workflow_id`.
- Returns GitHub run/job IDs, raw status (`queued`, `in_progress`, `completed`, and future states), raw conclusion, timestamps, branch/SHA, and detail URLs. Running/queued runs can have a null conclusion.
- CI output uses an explicit field projection. Logs and unrelated upstream fields are not exported.
- Does not use webhook-backed `batchCIStatus`, `ciStatusByProject`, CI update scan history, or usage/billing statistics as a substitute for live progress.
- No available run is distinct from a missing GitHub connection or failed request. Live read failures return an error rather than an old green result.

Errors distinguish expired sign-in, permission denial, missing/inaccessible resource or undeployed endpoint, unsupported method, expired GitHub resource, rate limits, incompatible responses, and other service failures. A 404 cannot reliably distinguish inaccessible repository from missing backend endpoint, so the response says so. Raw HTTP error bodies are withheld to avoid leaking credentials or internal data.

## Deliberate boundaries

The broader mobile dispatcher is not itself an MCP contract. Only catalogued operations can reach it. Key export/enrollment payloads, encrypted secret bundles, plaintext secret writes, upload-token minting, arbitrary menu commands, raw CI logs, and release token input are unavailable through MCP. Their supported native user flows are discoverable in the catalog. Background encrypted task activity and task claims remain owned by native sync/run orchestration, not arbitrary agent calls.

No new billing, subscription management, server deployment, account credential management, or undocumented cloud operations are assumed. Future additions need an explicit catalog contract, authorization review, handler, and tests.

## Verification

Focused verification for this implementation: four package contract tests and four app tests passed. The app tests cover mobile-operation allowlisting, CI progress projection, catalog/unsupported-operation handling, and suppression of raw permission-error bodies. The Debug app compiled as part of the focused Xcode test run. Whitespace checks passed for the touched implementation files.

These checks do not establish deployed backend availability, authenticated production document/CI reads, native passkey UI completion, email delivery, release dispatch, or other live mutations. Those require the updated running app and the corresponding signed-in connections.
