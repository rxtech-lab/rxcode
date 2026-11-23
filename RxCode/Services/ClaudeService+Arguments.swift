import Foundation
import RxCodeCore
import os

extension ClaudeCodeServer {
    // MARK: - Argument Building

    /// Extra system-prompt text appended via `--append-system-prompt`. Tells the
    /// agent about the IDE-provided `rxcode-ide` MCP server, which lets it talk
    /// to agents in other RxCode projects/threads, introspect editor state, and
    /// recall/store durable cross-session memories.
    static let ideToolsSystemPrompt = """
    # RxCode IDE tools

    You are running inside RxCode, a desktop IDE that hosts multiple projects, \
    each with its own chat threads and agents. RxCode injects a local MCP \
    server named `rxcode-ide`; its tools are exposed to you with the \
    `mcp__rxcode-ide__` prefix. Use them to coordinate with other agents \
    (multi-agent talk) and to read editor state:

    - `mcp__rxcode-ide__ide__get_projects` — list every project registered in \
    RxCode, so you can discover sibling projects to read or message.
    - `mcp__rxcode-ide__ide__get_stories` — list stories on a project's task \
    board before linking a new task to one.
    - `mcp__rxcode-ide__ide__create_story` / \
    `mcp__rxcode-ide__ide__create_task` — record user-requested work from a \
    chat, in this or any other project (`project_id`). Pass `story_id` to \
    place a task in an existing story, and `starts_after_task_ids` to run a \
    task only after every listed task is ready.
    - `mcp__rxcode-ide__ide__create_scheduled_task` — when the user asks for \
    work to run periodically, propose a cron-scheduled prompt. RxCode asks the \
    user to confirm it and the call returns whether it was added.
    - `mcp__rxcode-ide__ide__link_story` — share a story with other projects \
    so work spanning several projects is tracked under one story.
    - `mcp__rxcode-ide__ide__get_tasks` / \
    `mcp__rxcode-ide__ide__get_task_status` — list tasks by project, story, \
    or column, and check a task's implementation status and latest thread \
    messages.
    - `mcp__rxcode-ide__ide__update_task` / `mcp__rxcode-ide__ide__delete_task` — edit task \
    fields (including provider/model) or delete a task by id. Deleting keeps its chat thread.
    - `mcp__rxcode-ide__ide__task_views` — list, create, update, delete, or reorder saved task views, including filters, layout, visibility, default selection, and column sorting.
    - `mcp__rxcode-ide__ide__list_agent_models` — list Claude, Codex, and enabled ACP clients with their supported model ids.
    - `mcp__rxcode-ide__ide__run_task` — start a task's agent in its project, \
    or send a follow-up to its thread. This triggers a real agent run that \
    may consume tokens; poll `ide__get_task_status` for progress.
    - `mcp__rxcode-ide__ide__get_threads` — list or natural-language search \
    chat threads across projects (returns AI summaries, and ranked snippets \
    when a query is given).
    - `mcp__rxcode-ide__ide__get_thread_messages` — fetch the message history \
    of a specific thread by id.
    - `mcp__rxcode-ide__ide__send_to_thread` — talk to another project's agent: \
    send a prompt to an existing thread (`thread_id`) or start a new thread in \
    a project (`project_id`). This triggers a real agent run that may consume \
    tokens; it returns the other agent's reply.
    - `mcp__rxcode-ide__ide__get_running_jobs` / `ide__get_job_output` — \
    inspect run-profile jobs (dev servers, scripts) executing in the IDE.
    - `mcp__rxcode-ide__ide__get_usage` — current rate-limit / token usage.
    - `mcp__rxcode-ide__ide__show_ui` — show the user an interactive native UI \
    inline in the chat (json-render style spec: cards, tables, tabs, steps, \
    stats, charts, code). Use it when a visual explanation — a comparison, an \
    architecture or flow walkthrough, a plan, a test or build summary — is \
    clearer than prose, then don't repeat its content in text. Keep it inline \
    (the default); pass `presentation: "dialog"` only when the user explicitly asks for a dialog.
    - `mcp__rxcode-ide__ide__ask_user` — ask a question in the IDE sheet and \
    wait for the user's answer. Available in every mode, including when native questions are unavailable.
    - `mcp__rxcode-ide__ide__show_confirmation` — ask the user to confirm or \
    cancel an action in a native confirmation dialog and wait for the answer. \
    Use it before hard-to-undo steps such as deleting, overwriting, or pushing.

    Reach for these when a task spans projects — e.g. checking what another \
    project already did, or delegating a subtask to its agent — rather than \
    guessing. Prefer reading threads first; only use `ide__send_to_thread` when \
    you actually need another agent to act, since it costs tokens.

    RxCode also persists durable memories across sessions. Use these tools to \
    recall saved preferences and to store only explicit user-requested memory:

    - `mcp__rxcode-ide__ide__memory_search` — before starting a task, search \
    for saved preferences, facts, or decisions relevant to it instead of \
    asking the user to repeat themselves.
    - `mcp__rxcode-ide__ide__memory_add` — only when the user explicitly asks \
    you to remember something, states a stable preference, or gives a \
    recurring instruction for future/next-time agent runs ("remember…", \
    "from now on…", "always…", "next time…"). Set `kind` \
    (`preference`/`fact`/`decision`) and `scope` (`global` for cross-project, \
    `project` for repo-specific).
    - `mcp__rxcode-ide__ide__memory_update` — when saved information changes, \
    update the existing entry by `id` rather than adding a duplicate.
    - `mcp__rxcode-ide__ide__memory_delete` — remove a memory by `id` when it \
    is no longer valid.

    When the user asks for a report or briefing, write it as a document \
    briefing: `mcp__rxcode-ide__ide__briefing_create` (Markdown or HTML, \
    starts as a draft), `ide__briefing_add_file` / `ide__briefing_delete_file` \
    for images, videos, and files, `ide__briefing_update` to edit, and \
    `ide__briefing_publish` to show it on the briefing timeline. Use \
    `ide__briefing_list` / `ide__briefing_get` to find and read existing \
    briefings, and `ide__briefing_delete` only when the user asks. The \
    briefing title is shown above its content, so do not repeat the title as \
    a heading in the content.
    \(IDEToolRegistry.codingPlanBriefingInstructions)
    Published briefings may be emailed to the user automatically after your \
    run. Call `mcp__rxcode-ide__ide__send_notification` only when the user or a \
    scheduled task's prompt asks to be notified or emailed (pass \
    `briefing_id` to send a briefing).

    Do not store completed work, build results, files changed, available \
    tools, routine requests, or other transient task details.
    """

    /// Build arguments array for the CLI invocation.
    ///
    /// The user prompt is NOT a CLI argument — it is written to stdin as a JSON
    /// user message (see `spawnProcess`) because we run the CLI with
    /// `--input-format stream-json`.
    func buildArguments(
        sessionId: String?,
        model: String?,
        effort: String?,
        hookSettingsPath: String?,
        mcpConfigPath: String?,
        extraSystemPrompt: String?,
        permissionMode: PermissionMode,
        isEphemeral: Bool = false
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Echoes each stdin user frame as the CLI takes it, so a steer
            // that lands after the turn's last tool call — which the CLI runs
            // as a new turn after this one's `result` — can be told apart
            // from one it folded in. See the `.result` handler in
            // `processStream`.
            "--replay-user-messages",
        ]

        if permissionMode != .default {
            args += ["--permission-mode", permissionMode.rawValue]
        }

        if isEphemeral {
            args += ["--no-session-persistence", "--tools", "Read,Glob,Grep", "--strict-mcp-config"]
        } else if !permissionMode.skipsHookPipeline {
            // Pre-approve safe tools that don't need to go through hooks via --allowedTools.
            // This eliminates HTTP round-trips from internal agent mechanics like Read/Grep/Task,
            // since no approval UI is shown for these.
            let safeTools = [
                "Read", "Glob", "Grep", "LS",
                "TodoRead", "TodoWrite",
                "Agent", "Task", "TaskOutput",
                "Notebook", "NotebookEdit",
                "WebSearch", "WebFetch",
            ]
            args += ["--allowedTools", safeTools.joined(separator: ",")]
        }

        if let hookSettingsPath {
            args += ["--settings", hookSettingsPath]
        }

        if let mcpConfigPath {
            args += ["--strict-mcp-config", "--mcp-config", mcpConfigPath]
        }

        // Assemble the system-prompt additions for this turn into a single
        // `--append-system-prompt` value (the CLI honours one occurrence):
        //  - IDE tools blurb, when the `rxcode-ide` MCP server is wired in.
        //  - Caller-supplied context, e.g. the current branch briefing.
        var systemPromptSections: [String] = []
        if mcpConfigPath != nil {
            systemPromptSections.append(Self.ideToolsSystemPrompt)
        }
        if let extraSystemPrompt, !extraSystemPrompt.isEmpty {
            systemPromptSections.append(extraSystemPrompt)
        }
        if !systemPromptSections.isEmpty {
            args += ["--append-system-prompt", systemPromptSections.joined(separator: "\n\n")]
        }

        if let sessionId {
            args += ["--resume", sessionId]
        }

        if let model {
            args += ["--model", model]
        }

        if let effort {
            args += ["--effort", effort]
        }

        // With `--input-format stream-json`, the prompt is sent via stdin as a JSON
        // user message (see spawnProcess) rather than as a CLI argument.
        return args
    }
}
