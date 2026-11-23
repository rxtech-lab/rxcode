import Foundation

/// Presentation strings for tool activity. Dispatch and permissions continue to use the original identifier.
public enum ToolActionName {
    private static let ideLabels = [
        "add_todo": "Adding a to-do",
        "add_todos": "Adding to-dos",
        "app_click": "Clicking a window",
        "app_inspect": "Inspecting a window",
        "app_list_windows": "Listing windows",
        "app_screenshot": "Capturing a window",
        "app_type": "Typing in a window",
        "ask_user": "Asking a question",
        "briefing_add_file": "Attaching a briefing file",
        "briefing_create": "Drafting a briefing",
        "briefing_delete": "Deleting a briefing",
        "briefing_delete_file": "Removing a briefing file",
        "briefing_get": "Reading a briefing",
        "briefing_list": "Listing briefings",
        "briefing_publish": "Publishing a briefing",
        "briefing_update": "Updating a briefing",
        "browser_click": "Clicking a page element",
        "browser_close_tab": "Closing a browser tab",
        "browser_inspect": "Inspecting a web page",
        "browser_navigate": "Navigating the browser",
        "browser_open": "Opening a web page",
        "browser_screenshot": "Capturing a web page",
        "browser_select_tab": "Switching browser tabs",
        "browser_tabs": "Listing browser tabs",
        "browser_type": "Typing on a web page",
        "create_scheduled_task": "Scheduling a task",
        "create_story": "Creating a story",
        "create_task": "Creating a task",
        "delete_task": "Deleting a task",
        "document_preview": "Previewing a document",
        "flowcy": "Using Flowcy",
        "flowcy_catalog": "Browsing Flowcy tools",
        "generate_media": "Generating media",
        "get_ci_status": "Checking CI status",
        "get_integration_usage": "Checking integration usage",
        "get_job_output": "Reading job output",
        "get_projects": "Listing projects",
        "get_running_jobs": "Checking running jobs",
        "get_stories": "Listing stories",
        "get_task_status": "Checking task status",
        "get_tasks": "Listing tasks",
        "get_thread_detail": "Reading thread details",
        "get_thread_messages": "Reading thread messages",
        "get_threads": "Finding threads",
        "get_usage": "Checking usage",
        "link_story": "Updating story links",
        "list_agent_models": "Listing agent models",
        "media_models": "Listing media models",
        "memory_add": "Saving a memory",
        "memory_delete": "Deleting a memory",
        "memory_list": "Listing memories",
        "memory_search": "Searching memories",
        "memory_update": "Updating a memory",
        "pet_capture": "Taking a screenshot",
        "pet_click": "Clicking on the desktop",
        "pet_draft": "Preparing a draft",
        "pet_focus_window": "Focusing a window",
        "pet_list_capture_targets": "Finding capture targets",
        "pet_list_desktop_targets": "Finding windows and displays",
        "pet_look": "Managing pet appearance",
        "pet_music": "Controlling music",
        "pet_schedule": "Managing pet reminders",
        "pet_scroll": "Scrolling",
        "pet_show_image": "Showing an image",
        "pet_status": "Updating pet status",
        "pet_type_text": "Typing text",
        "pet_voice_history": "Managing voice history",
        "project_briefing_get": "Reading a project briefing",
        "project_briefings": "Listing project briefings",
        "run_task": "Running a task",
        "search_docs": "Searching documentation",
        "search_huggingface_models": "Searching Hugging Face models",
        "send_notification": "Sending a notification",
        "send_to_thread": "Messaging a thread",
        "set_todos": "Updating to-dos",
        "setup_docs_secret": "Setting up documentation publishing",
        "setup_release": "Setting up releases",
        "show_confirmation": "Requesting confirmation",
        "show_ui": "Showing a view",
        "simulator_inspect": "Inspecting the simulator",
        "simulator_list": "Listing simulators",
        "simulator_screenshot": "Capturing the simulator",
        "simulator_tap": "Tapping the simulator",
        "simulator_type": "Typing in the simulator",
        "skill_get": "Loading a skill",
        "swiftui_preview": "Rendering a SwiftUI preview",
        "task_views": "Managing task views",
        "todos": "Adding a to-do",
        "update_task": "Updating a task",
        "usage_cards": "Checking usage",
    ]

    private static let nativeLabels = [
        "agent": "Running a subagent",
        "apply_patch": "Applying a patch",
        "askuserquestion": "Asking a question",
        "bash": "Running a command",
        "command_execution": "Running a command",
        "commandexecution": "Running a command",
        "edit": "Editing a file",
        "enterplanmode": "Planning",
        "exec_command": "Running a command",
        "execute": "Running a command",
        "exit_plan_mode": "Finishing the plan",
        "exitplanmode": "Finishing the plan",
        "filechange": "Editing files",
        "glob": "Finding files",
        "grep": "Searching code",
        "imagegeneration": "Generating an image",
        "interactive_terminal": "Using the terminal",
        "list": "Listing files",
        "list_mcp_resource_templates": "Listing MCP resource templates",
        "list_mcp_resources": "Listing MCP resources",
        "ls": "Listing files",
        "mcptoolcall": "Using an MCP tool",
        "multi_edit": "Editing multiple locations",
        "multiedit": "Editing multiple locations",
        "notebookedit": "Editing a notebook",
        "read": "Reading a file",
        "read_file": "Reading a file",
        "read_mcp_resource": "Reading an MCP resource",
        "request_user_input": "Asking a question",
        "run_command": "Running a command",
        "run_shell_command": "Running a command",
        "run_terminal_cmd": "Running a command",
        "search": "Searching",
        "shell": "Running a command",
        "skill": "Loading a skill",
        "task": "Running a subagent",
        "taskcreate": "Creating a task",
        "taskget": "Reading a task",
        "tasklist": "Listing tasks",
        "taskoutput": "Reading task output",
        "taskstop": "Stopping a task",
        "taskupdate": "Updating a task",
        "terminal": "Using the terminal",
        "todoread": "Reading to-dos",
        "todowrite": "Updating to-dos",
        "toolsearch": "Finding tools",
        "update_plan": "Updating the plan",
        "videogeneration": "Generating a video",
        "view_image": "Viewing an image",
        "webfetch": "Fetching a web page",
        "websearch": "Searching the web",
        "write": "Writing a file",
        "write_stdin": "Interacting with the terminal",
    ]

    static let ideServers = ["rxcode-ide", "rxcode_ide", "rxcode"]

    /// Resolves an IDE operation without treating a third-party server's matching tool as a built-in.
    static func ideOperation(for identifier: String) -> String? {
        let parts = identifier.lowercased().components(separatedBy: "__")
        switch parts.count {
        case 1: return ideLabels[parts[0]] == nil ? nil : parts[0]
        case 2 where parts[0] == "ide": return parts[1]
        case 3 where parts[0] == "mcp" && (ideServers.contains(parts[1]) || parts[1] == "ide"):
            return parts[2]
        case 4 where parts[0] == "mcp" && ideServers.contains(parts[1]) && parts[2] == "ide":
            return parts[3]
        case 4 where parts == ["mcp", "add", "ide", "todos"]: return "add_todo"
        default: return nil
        }
    }

    public static func systemLabel(for name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let native = nativeLabels[key] { return native }
        if key.hasPrefix("functions.") { return nativeLabels[String(key.dropFirst(10))] }
        if let operation = ideOperation(for: key) { return ideLabels[operation] }
        if key.hasPrefix("mcp__"), ideServers.contains(String(key.dropFirst(5))) {
            return "Using an IDE tool"
        }
        return nil
    }

    /// A synchronous label to use while an external tool name is being humanized or the model is unavailable.
    public static func fallbackLabel(for name: String) -> String {
        let leaf = name.components(separatedBy: "__").last ?? name
        let words = leaf
            .replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return "Using a tool" }
        let tail = words.dropFirst().map { $0 == $0.uppercased() ? String($0) : $0.lowercased() }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + tail).joined(separator: " ")
    }
}
