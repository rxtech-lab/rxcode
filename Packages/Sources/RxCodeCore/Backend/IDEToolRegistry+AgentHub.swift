import Foundation

/// Tools only an agent's own threads see. They are not part of `allTools`;
/// `AppState.ideAvailableTools(forSession:)` adds them for sessions that
/// belong to an agent from the Agents tab.
extension IDEToolRegistry {
    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    public static let agentMemoryTool = IDETool(
        name: "ide__agent_memory",
        description: "Read and maintain your own durable memory as an RxCode agent. action=list returns every note; add saves a new note; update replaces a note's content; delete removes one. Save preferences, facts and decisions worth keeping across conversations. Keep notes short and current; update instead of duplicating.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "action": string("list, add, update or delete.", enum: ["list", "add", "update", "delete"]),
            "id": string("Note id for update and delete."),
            "content": string("Note text for add and update."),
            "kind": string("preference, fact, decision or note. Defaults to note.", enum: ["preference", "fact", "decision", "note"]),
        ], required: ["action"])
    )

    public static let agentSpawnSubagentTool = IDETool(
        name: "ide__agent_spawn_subagent",
        description: "Delegate a self-contained job to a subagent that works in the background in its own thread. Returns the job id immediately; you are told in your conversation when it finishes, with its report. Write the prompt so it can be done without asking questions. Optionally pick another provider/model from ide__list_agent_models.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "title": string("Short name shown in the jobs list."),
            "prompt": string("Complete instructions for the subagent."),
            "provider": string("Optional provider: claudeCode, codex, acp or localAgent. Defaults to yours."),
            "model": string("Optional model id for that provider. Defaults to yours."),
        ], required: ["title", "prompt"])
    )

    public static let agentRunBackgroundTaskTool = IDETool(
        name: "ide__agent_run_background_task",
        description: "Run a shell command in the background with /bin/zsh -lc. Returns the job id immediately; you are told in your conversation when it exits, with its exit status and output tail. Use it for builds, downloads and long scripts. The command runs with the user's privileges, so never run destructive commands without the user's approval.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "title": string("Short name shown in the jobs list."),
            "command": string("The shell command line."),
            "working_directory": string("Optional absolute folder. Defaults to your working folder."),
            "timeout_seconds": number("Optional limit after which the command is stopped. Defaults to 3600, at most 86400."),
        ], required: ["title", "command"])
    )

    public static let agentJobsTool = IDETool(
        name: "ide__agent_jobs",
        description: "Manage your subagents and background tasks. action=list returns recent jobs with status; get returns one job's full result; cancel stops a queued or running job.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "action": string("list, get or cancel.", enum: ["list", "get", "cancel"]),
            "job_id": string("Job id for get and cancel."),
            "include_finished": boolean("For list: include finished jobs. Defaults to true."),
        ], required: ["action"])
    )

    public static let agentScheduleTool = IDETool(
        name: "ide__agent_schedule",
        description: "Manage your own schedules. Each run is handled by a subagent that reports back to you when it finishes. action=list shows them; create needs name, prompt and either cron (five-field, local time) or run_at (ISO 8601, for a one-off); update changes the given fields; delete removes one; run_now starts a run immediately. Only create schedules the user asked for.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "action": string("list, create, update, delete or run_now.", enum: ["list", "create", "update", "delete", "run_now"]),
            "schedule_id": string("Schedule id for update, delete and run_now."),
            "name": string("Short name."),
            "prompt": string("What the subagent should do on each run."),
            "cron": string("Five-field cron expression such as \"0 8 * * 1-5\"."),
            "run_at": string("ISO 8601 date-time for a one-off run, instead of cron."),
            "enabled": boolean("Whether the schedule runs."),
        ], required: ["action"])
    )

    public static let agentContactTool = IDETool(
        name: "ide__agent_contact",
        description: "Work with the other agents the user created in RxCode. action=list returns your teammates with what each is for and whether it is busy; send asks one teammate (by agent_id or name) to do something. The teammate works on it as itself, with its own memory, model and tools, in a separate thread. Returns a job id immediately; its reply is delivered to your conversation when it finishes, so don't poll.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "action": string("list or send.", enum: ["list", "send"]),
            "agent": string("For send: the teammate's agent_id or name."),
            "title": string("For send: a short name for the request, shown in both agents' activity."),
            "message": string("For send: the complete request, with the context the teammate needs."),
        ], required: ["action"])
    )

    public static let agentNotifyUserTool = IDETool(
        name: "ide__agent_notify_user",
        description: "Send a short message to the user's paired phone as a push notification that opens your conversation in the Chat tab. Use it when something needs their attention while they may be away from the Mac. The message also appears in your conversation.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "message": string("The message, up to a few sentences. Markdown is shown as plain text in the notification."),
            "title": string("Optional notification title. Defaults to your name."),
        ], required: ["message"])
    )

    public static let computerScreenshotTool = IDETool(
        name: "ide__computer_screenshot",
        description: "Take a screenshot of one of the Mac's displays. Returns the image and its pixel size; ide__computer_action coordinates use this pixel space. Lists the displays when there are several.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "display_id": number("Optional display id. Defaults to the main display."),
        ])
    )

    public static let computerActionTool = IDETool(
        name: "ide__computer_action",
        description: "Operate the Mac's mouse and keyboard, then return a fresh screenshot. Coordinates are pixels in the latest ide__computer_screenshot of the same display. Actions: click, double_click, right_click, move, drag (x,y to to_x,to_y), scroll (direction and amount in pixels), type (text), key (a combination like cmd+space, return or ctrl+shift+tab), wait (seconds).",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "action": string("The action.", enum: ["click", "double_click", "right_click", "move", "drag", "scroll", "type", "key", "wait"]),
            "x": number("Horizontal pixel position."),
            "y": number("Vertical pixel position."),
            "to_x": number("Drag end, horizontal pixel."),
            "to_y": number("Drag end, vertical pixel."),
            "direction": string("Scroll direction.", enum: ["up", "down", "left", "right"]),
            "amount": number("Scroll distance in pixels. Defaults to 400."),
            "text": string("Text to type."),
            "keys": string("Key combination for action=key."),
            "seconds": number("Seconds to wait for action=wait, at most 10."),
            "display_id": number("Display the coordinates belong to. Defaults to the main display."),
        ], required: ["action"])
    )

    public static let computerDelegateTool = IDETool(
        name: "ide__computer_delegate",
        description: "Hand one concrete GUI task to the open-source computer-use agent (cua), which sees the screen and operates the mouse and keyboard with its own vision model. Returns its report. Use small, specific tasks and check results before continuing.",
        visibility: .alwaysIDEOnly,
        inputSchema: object([
            "task": string("One concrete task, such as \"open System Settings and turn on Do Not Disturb\"."),
        ], required: ["task"])
    )

    /// Tools for an agent thread, by role and computer-use driver.
    public static func agentHubTools(
        isConversation: Bool,
        notifiesPhone: Bool,
        computerUse: AgentComputerUseDriver?,
        hasTeammates: Bool = false
    ) -> [IDETool] {
        var tools = [agentMemoryTool]
        if isConversation {
            tools += [agentSpawnSubagentTool, agentRunBackgroundTaskTool, agentJobsTool, agentScheduleTool]
            if hasTeammates { tools.append(agentContactTool) }
        }
        if notifiesPhone { tools.append(agentNotifyUserTool) }
        switch computerUse {
        case .native: tools += [computerScreenshotTool, computerActionTool]
        case .openSource: tools.append(computerDelegateTool)
        case nil: break
        }
        return tools
    }

    /// Every agent and computer-use tool name, for dispatch.
    public static let agentHubToolNames: Set<String> = [
        agentMemoryTool.name, agentSpawnSubagentTool.name, agentRunBackgroundTaskTool.name, agentJobsTool.name,
        agentScheduleTool.name, agentContactTool.name, agentNotifyUserTool.name, computerScreenshotTool.name, computerActionTool.name,
        computerDelegateTool.name,
    ]
}
