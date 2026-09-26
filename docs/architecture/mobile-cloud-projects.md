# Mobile cloud projects

The iOS app can sign in to Autopilot using the same RxAuth OAuth client and PKCE flow as macOS. The `rxcode://oauth-callback` URL scheme is registered in both app targets. Tokens remain in the app's Keychain; the shared HTTP client retries a rejected bearer once after refreshing it.

The normal Tasks dashboard, board, detail views, and task/story forms serve both paired desktops and cloud projects. A connected Mac opens the regular workspace. While disconnected, **View Tasks** on onboarding or the connection screen opens those same task views backed directly by HTTPS; the app uses its shared account sign-in. There is no separate Autopilot workspace or switch button. Cloud access requires internet but does not require a laptop connection.

`MobileAppState+CloudTasks` adapts the existing task commands to the cloud API and keeps cloud snapshots separate from desktop snapshots. `TaskBoard.replacingCloudRows` uses the shared model's field mapping, parent rules, filters, and story rollups. The desktop and mobile Kanban columns share `TaskKanbanColumnContent`. Cloud saved views are account-scoped local presentation preferences. Agent runs, follow-ups, and AI quick-add require a connected Mac.

Macs register an account-specific stable device ID and display name when refreshing cloud projects. Task assignment stores `assignedDeviceId` in Autopilot and survives laptop disconnection. The picker lists the signed-in account's registered Macs. Desktop board synchronization preserves assignment, and a Mac refuses to start a task assigned to another Mac. Assignment and cloud status edits do not queue or automatically start an agent run.

## Backend rollout

The companion `github-pm` change adds authenticated `GET`/`PUT /api/v1/devices`, task assignment validation, and migration `0030_account_devices`. Deploy that backend with the migration before shipping the clients. This implementation does not apply production database migrations or deploy the service. Cloud task editing works through the existing repository board endpoints; the UI displays a separate error if laptop discovery is unavailable.

## Verification

- `CloudLaptopAssignmentTests`: old-board decoding, assignment merge, and clearing.
- `ProjectCloudServiceTests`: bearer refresh, pagination, repeated unauthorized responses, and assignment PATCH errors.
- `CloudWorkspaceUITests`: connected-Mac navigation, cloud task/story creation and editing through the regular board, and access with an unreachable paired Mac, using Debug-only network fixtures.
- `CloudTaskBoardMappingTests`: stable navigation IDs, story and parent links, classification types, deletions, and saved filters.
- Backend route/service tests: account authentication, registration ownership, assignment persistence, and cross-account rejection.

The UI fixture does not validate a live OAuth browser session or production deployment.
