import Foundation
import RxCodeCore
import os

extension CodexAppServer {
    func initializeParams() -> [String: JSONValue] {
        [
            "clientInfo": .object([
                "name": .string("RxCode"),
                "title": .string("RxCode"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            ]),
            "capabilities": .object([:])
        ]
    }

    func threadParams(threadId: String?, cwd: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let threadId { params["threadId"] = .string(threadId) }
        return params
    }

    func threadStartParams(threadId: String?, cwd: String, permissionMode: PermissionMode, planMode: Bool, ideInstructions: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let threadId { params["threadId"] = .string(threadId) }
        params["approvalPolicy"] = .string(Self.codexApprovalPolicy(permissionMode: permissionMode, planMode: planMode))
        params["sandbox"] = .string(Self.codexSandboxMode(permissionMode: permissionMode, planMode: planMode))
        var instructions: [String] = []
        if let ideInstructions, !ideInstructions.isEmpty { instructions.append(ideInstructions) }
        if planMode { instructions.append(Self.planModeInstructions) }
        if !instructions.isEmpty {
            params["developerInstructions"] = .string(instructions.joined(separator: "\n\n"))
        }
        return params
    }

    func turnParams(threadId: String, prompt: String, cwd: String, model: String?, permissionMode: PermissionMode, planMode: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "cwd": .string(cwd),
            "input": .array([
                .object(["type": .string("text"), "text": .string(prompt)])
            ])
        ]
        if let model { params["model"] = .string(model) }
        params["approvalPolicy"] = .string(Self.codexApprovalPolicy(permissionMode: permissionMode, planMode: planMode))
        params["sandboxPolicy"] = Self.codexSandboxPolicy(permissionMode: permissionMode, planMode: planMode)
        return params
    }

    static let planModeInstructions = """
    Plan mode is enabled. Produce a clear, step-by-step plan using the update_plan tool. \
    Do not modify files; do not run commands that mutate state. \
    Read-only inspection is allowed. End with a concise summary of the proposed plan and \
    wait for the user to disable plan mode before making changes.
    """

    /// Developer-role instructions handed to Codex on `thread/start`. Tells the
    /// agent about the IDE-provided `rxcode-ide` MCP server — cross-project
    /// chat, thread history, running jobs, usage, and durable cross-session
    /// memory. Only emitted when the IDE MCP bridge is wired into the turn.
    static let ideToolsDeveloperInstructions = """
    # RxCode IDE tools

    You are running inside RxCode, a desktop IDE that hosts multiple projects, \
    each with its own chat threads and agents. RxCode wires in a local MCP \
    server named `rxcode-ide`; its tools appear in your available tools list. \
    Use them to coordinate with other agents and to read editor state:

    - `ide__get_projects` — list every project registered in RxCode, so you \
    can discover sibling projects to read or message.
    - `ide__get_threads` — list or natural-language search chat threads across \
    projects.
    - `ide__get_thread_messages` — fetch the message history of a specific \
    thread by id.
    - `ide__send_to_thread` — talk to another project's agent: send a prompt \
    to an existing thread or start a new thread in a project. This triggers a \
    real agent run that may consume tokens; it returns the other agent's reply.
    - `ide__get_running_jobs` / `ide__get_job_output` — inspect run-profile \
    jobs executing in the IDE.
    - `ide__get_usage` — current rate-limit / token usage.

    Reach for these when a task spans projects rather than guessing. Prefer \
    reading threads first; only use `ide__send_to_thread` when you actually \
    need another agent to act, since it costs tokens.

    RxCode also persists durable memories — stable user preferences, project \
    facts, and decisions — across sessions. Use these tools to recall and \
    store them:

    - `ide__memory_search` — before starting a task, search for saved \
    preferences, facts, or decisions relevant to it instead of asking the \
    user to repeat themselves.
    - `ide__memory_add` — when the user states a stable preference, project \
    fact, or decision ("remember…", "from now on…", "always…"), save it. Set \
    `kind` (`preference`/`fact`/`decision`) and `scope` (`global` for \
    cross-project, `project` for repo-specific).
    - `ide__memory_update` — when saved information changes, update the \
    existing entry by `id` rather than adding a duplicate.
    - `ide__memory_delete` — remove a memory by `id` when it is no longer valid.

    Only store stable, reusable information in memory — not transient task \
    details.
    """

    /// True when the `rxcode-ide` MCP bridge is present in the `-c` overrides.
    static func includesIDEServer(_ overrides: [String]) -> Bool {
        overrides.contains { $0.hasPrefix("mcp_servers.rxcode-ide=") }
    }

    static func codexApprovalPolicy(permissionMode: PermissionMode, planMode: Bool) -> String {
        if planMode { return "on-request" }
        switch permissionMode {
        case .default, .plan: return "untrusted"
        case .acceptEdits, .auto: return "on-request"
        case .bypassPermissions: return "never"
        }
    }

    static func codexSandboxMode(permissionMode: PermissionMode, planMode: Bool) -> String {
        if planMode { return "read-only" }
        switch permissionMode {
        case .bypassPermissions: return "danger-full-access"
        default: return "workspace-write"
        }
    }

    static func codexSandboxPolicy(permissionMode: PermissionMode, planMode: Bool) -> JSONValue {
        if planMode {
            return .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        }
        switch permissionMode {
        case .bypassPermissions:
            return .object(["type": .string("dangerFullAccess")])
        default:
            return .object(["type": .string("workspaceWrite")])
        }
    }

    static func request(id: Int, method: String, params: [String: JSONValue]) -> JSONValue {
        request(id: id, method: method, params: .object(params))
    }

    static func request(id: Int, method: String, params: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    static func response(id: String, result: [String: JSONValue]) -> JSONValue {
        let idValue = Double(id).map(JSONValue.number) ?? .string(id)
        return .object(["jsonrpc": .string("2.0"), "id": idValue, "result": .object(result)])
    }

    static func notification(method: String, params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
    }

    static func writeJSONLine(_ value: JSONValue, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    static func decodeObject(_ line: String) -> [String: JSONValue]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value.objectValue
    }

    static func decodeJSONValue(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
