# Desktop marketing captures

Native RxCode debug app screenshots captured on macOS on October 30, 2026. All projects, tasks, schedules, briefings, and conversations are fictional fixtures from `RxCode/App/AppState+Screenshots.swift`. Statements about test results inside the conversation are mock content.

- `workspace.webp`: project chat with rendered Markdown, 2880 × 1800.
- `board.webp`: task board with Claude Code, Codex, and ACP assignments, 2880 × 1800.
- `briefing.webp`: rendered branch briefing, 2880 × 1800.
- `schedules.webp`: three paused schedules, 2880 × 1800.
- `task-details.webp`: dedicated native task sheet, 1120 × 1360.

Run `scripts/prepare-marketing-screenshots.sh` from the repository, then open the prepared copy. Its separate bundle identifier (`com.rxlab.RxCode.screenshots`) activates the debug-only fixture path. It uses a separate temporary Application Support directory and bypasses normal workspace loading and background agent/sync startup. Schedules are paused and no prompt needs to be sent. The normal app's projects and chats are not used.

Capture the app window through the desktop capture tool. Use Projects → Orbit Studio for the board, the task title for its sheet, Briefing with the Orbit Studio project filter, and Scheduled. To open a saved conversation, use the sidebar history button, select the fictional Orbit Studio thread, and close the history sheet. The landing page uses Next Image to serve responsive versions and preserve each capture's aspect ratio.

The phone in the remote section is a fictional web illustration, not a mobile screenshot. This gallery only presents captures of the desktop app.
