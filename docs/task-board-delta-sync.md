# Flowcy task-board synchronization

The existing github-pm tasks and board-views routes return full documents. The existing activity cursor orders a single listing by task ID and sender. A client needs a server-issued checkpoint before it can request changes. The following contract extends the existing authenticated repository routes. Deployments can roll out board and activity support independently.

| GET resource | Full response additions | Request after initial load |
| --- | --- | --- |
| tasks | Optional opaque string checkpoint and integer savedViewsRevision | since=checkpoint, optionally cursor=nextCursor |
| activity | Optional opaque string checkpoint on every page | recipient and since=checkpoint, optionally cursor=nextCursor |

A checkpoint identifies a committed snapshot in the authorized account and project. Activity checkpoints also bind the recipient. Authorize each page before serving data. A page cursor binds the original checkpoint, scope, and fixed target snapshot. Include concurrent changes after that target in the next exchange. Return HTTP 410 when history or the cursor expires. Return the existing access error when authorization fails. A server rollback may ignore since and return the legacy full response. The client never uses a pagination cursor as a checkpoint.

Board delta pages contain the target checkpoint, full upsert rows in tasks and stories, deletedTaskIds and deletedStoryIds arrays, and nullable nextCursor. Send members, role, currentUserId and savedViewsRevision as full snapshot metadata even on empty pages. Include side effects such as cleared parent links. Use creation dates and task sort indices from the full response. Return each entity's final state once per snapshot. The initial tasks response retains its existing full-board shape. The checkpoint covers membership, role and saved-view revision changes. Saved views remain a separately authorized, revision-checked resource.

Activity pages retain items and nextCursor. Delta pages add deletedTaskIds and the target checkpoint. Items remain opaque envelopes keyed by task ID and sender. To replace the sender set for a task, emit its deletion once before its complete surviving set of envelopes. A recipient losing visibility must receive a tombstone for that visibility change. Keep pages byte-bounded. Retain the old full-list behavior without since.

RxCode commits a complete snapshot and its checkpoint together after the final page. Disk cache eviction causes a full read. Every warm read still contacts the authorized server. Failed pages leave the previous baseline available for retry. Desktop periodic checks back off from 30 to 120 seconds on unchanged boards. Explicit refresh and local edit scheduling bypass the delay.

## Local comparison

Run `swift test --package-path Packages --filter ProjectCloudSyncTests`. The changedFieldsAndPayloadComparison fixture compares a full task with 4 KiB of unchanged details against a PATCH clearing just its priority. Both paths issue one request. For steady-state desktop scheduling, four 30-second polling opportunities for one unchanged linked project used to issue four tasks GETs and four board-views GETs. With an already verified unchanged board and a matching saved-view revision, a 120-second interval issues one tasks GET and zero view GETs. A legacy backend requires one full board GET and one view GET per backed-off interval. These counts exclude project discovery, activity, user edits, activation and manual refresh. They model client requests and JSON body bytes only.

The 200-task unchanged-board fixture (4 KiB of details per task) encodes 824,331 bytes for the full snapshot and 83 bytes for the empty delta. The priority-clear fixture encodes 4,362 bytes for the full task and 17 bytes for the sparse PATCH. These are uncompressed synthetic bodies.
