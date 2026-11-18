# Pet voice continuity, memory and scheduled reports

Microphone mute gates capture only. It does not stop a voice connection, flush assistant audio, clear history, or silence reports. Starting a new call while muted leaves capture disabled until unmute.

## Completion speech

Completion hooks identify each agent turn by its stream ID. Repeated delivery of that ID is ignored; a turn with queued follow-ups is not announced as finished. Off and silent proactive-notification preferences apply during calls too.

Codex notifications use `thread/realtime/appendSpeech` on the existing thread, for both WebRTC and WebSocket. `appendText` alone does not request speech. The queue waits for a conversational gap, pending hardware playback and a short quiet interval. It keeps a submitted batch until a completed assistant transcript is received. No separate local voice competes with a realtime reply. Ambiguous RPC failures retain the batch and require restarting the call to retry, rather than automatically submitting it twice.

## Transcript continuity

Completed text actually received by RxCode is saved under the bundle-scoped Application Support directory in `pet-voice-history`. Each workspace/pinned-project scope has a stable conversation ID; each call and turn has a stable ID. Repeated polling snapshots do not append duplicate turns. Partial transcripts and unreceived audio are not reconstructed.

Typed chats, local voice calls and Codex Realtime calls share this archive. The companion window restores its transcript when reopened. Each new conversation receives a deterministic extractive summary of at most 6,000 characters in its instructions. It includes bounded excerpts of earlier constraints, recent requests, reported decisions/results and outstanding work, with turn identifiers. Excerpts are history, not fresh instructions or independently verified outcomes. The summary is not sent as a speech request or replayed as user turns.

`ide__pet_voice_history` reads the same archive. Follow `next_cursor` until exhausted; pages contain up to 50 turn parts and at most 8,000 text characters. Long turns are split with stable turn IDs and text offsets, so pagination can retrieve the complete stored text. A cursor is scoped to its conversation. `action=clear` requires a native confirmation and rotates the conversation ID so late writes from the old call cannot restore deleted history. The current model can still remember its in-flight context until hangup.

## User-global memory

Pets reuse the existing MemoryRecord table, IDE memory tools, and Settings → General → Memory. Global records are indexed once and stored in the personal workspace's existing database; existing workspace-global records migrate there by ID. Project-scoped records remain local to their project/workspace. Global records are shared across pet looks and new text/voice sessions on this Mac. This adds no cloud or cross-device sync.

Only explicit remember/update/forget requests belong in durable memory. Transcript archives, background reports and incidental speech are not automatically promoted. `ide__memory_add`, `ide__memory_search`, `ide__memory_list`, `ide__memory_update` and `ide__memory_delete` operate on the same records as Settings. Pet additions default to pet scope; global scope is used only when the user asks for the memory to apply to every agent, and project facts require an explicit project scope/ID. Startup context includes at most six bounded pet and global excerpts, subject to existing memory/injection settings. Additional details are retrieved through tools. Forgetting a memory is separate from clearing transcript history.

## Scheduled reminders and progress reporting

For a general reminder, call `ide__pet_schedule` with `after_seconds`, a name, and `instructions` containing the reminder text. Omit `project_id`; `kind` defaults to `reminder`. No active or pinned project is inferred. At due time the saved text goes directly to the caption/spoken-notification outbox without querying project state or dispatching an agent. `kind=progress` requires an explicit project ID; supplying a project ID without a kind preserves the existing progress-check behavior. Legacy progress records without a kind retain that behavior.

Both kinds appear under sidebar **General → Scheduled**, labeled **Pet reminder** or **Pet progress report**. The tool lists both, including their IDs, kind, project (null for reminders), and execution/delivery state. Edits preserve the existing kind and time when omitted; cancellation prevents future execution and removes queued delivery that has not already started.

For “in two minutes, check progress and tell me”, resolve the project, then call `ide__pet_schedule` with `after_seconds=120`, `kind=progress`, and the resolved `project_id`. This creates a one-off instant, not a cron. Explicit ISO8601 instants and local `yyyy-MM-dd HH:mm` times with an IANA timezone are supported; the timezone is persisted. Actual recurring checks use cron. Scheduling/editing uses the existing native task proposal sheet; list/cancel use the same tool, and tasks remain visible in Scheduled.

At due time, RxCode durably claims the task before querying task-board state, saved threads and live agent activity. The request text is context, not an executable merge/deploy instruction. Reports distinguish board labels and unverified agent reports from proof of tests, merges or deployments. No agent is dispatched for a progress check.

Unclaimed overdue one-offs run once after launch or wake. A claimed check interrupted by app exit is shown as interrupted and is not silently rerun. Cancellation/editing before execution invalidates the claim. Reports persist in an outbox until caption/speech delivery is acknowledged. Disabled pets or Off preferences retain pending reports; silent preference delivers a caption. A pending report pauses later recurring checks so it is not overwritten. Delivery never opens a microphone or starts a call.

The app must be running to execute a reminder or check; a closed app catches up on launch rather than running in the background. Native sleep/wake, live provider speech and audible delivery require runtime verification. No system can atomically commit remote audible playback and a local disk acknowledgement: a crash or disconnect around that boundary can leave an ambiguous pending report. Stored claims prevent duplicate one-off check execution; the outbox avoids silently discarding unacknowledged reports.
