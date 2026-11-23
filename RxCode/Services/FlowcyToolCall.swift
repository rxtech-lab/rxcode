import Foundation
import RxAgentHarness
import RxCodeCore

/// Client-executed Flowcy tools. A call must match a tool offered for this turn.
nonisolated struct FlowcyToolCall {
    static let terminalDefinition: JSONValue = .object([
        "name": .string("bash"),
        "description": .string("Run a shell command on the user's Mac in the selected project or Git worktree and return its output."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object(["command": .object(["type": .string("string")])]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false),
        ]),
    ])

    static let questionDefinition: JSONValue = .object([
        "name": .string(IDEToolRegistry.askUser.name),
        "description": .string(IDEToolRegistry.askUser.description),
        "inputSchema": IDEToolRegistry.askUser.inputSchema,
    ])

    private enum Action {
        case terminal(String)
        case question([String: JSONValue])
    }

    let id: String
    private let action: Action

    private var name: String {
        switch action {
        case .terminal: "bash"
        case .question: IDEToolRegistry.askUser.name
        }
    }
    var displayName: String { name == "bash" ? "Bash" : name }
    var input: [String: JSONValue] {
        switch action {
        case .terminal(let command): ["command": .string(command)]
        case .question(let arguments): arguments
        }
    }

    init?(event: JSONValue, terminalEnabled: Bool, questionEnabled: Bool) {
        guard let id = event["id"]?.stringValue, !id.isEmpty,
              let arguments = event["arguments"]?.objectValue else { return nil }
        switch event["name"]?.stringValue {
        case "bash" where terminalEnabled:
            guard arguments.count == 1, let command = arguments["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.utf8.contains(0) else { return nil }
            action = .terminal(command)
        case IDEToolRegistry.askUser.name where questionEnabled:
            guard (try? IDEUserQuestion(.object(arguments))) != nil else { return nil }
            action = .question(arguments)
        default: return nil
        }
        self.id = id
    }

    // The permission queue is shared by all threads. Scope remote IDs to the local turn,
    // and preserve the provider's original ID for replay of completed call/result pairs.
    func localID(streamID: UUID) -> String { "flowcy:\(streamID.uuidString):\(id)" }

    init?(saved: ToolCall) {
        let parts = saved.id.split(separator: ":", maxSplits: 2)
        guard saved.name == "Bash", parts.count == 3, parts[0] == "flowcy",
              let command = saved.input["command"]?.stringValue else { return nil }
        id = String(parts[2])
        action = .terminal(command)
    }

    var callPart: JSONValue {
        .object(["type": .string("tool-call"), "toolCallId": .string(id),
                 "toolName": .string(name), "input": .object(input)])
    }

    func resultPart(_ text: String, isError: Bool) -> JSONValue {
        .object(["type": .string("tool-result"), "toolCallId": .string(id), "toolName": .string(name),
                 "output": .object(["type": .string(isError ? "error-text" : "text"), "value": .string(text)])])
    }

    func execute(request: BackendSendRequest, sessionID: String, permission: PermissionServer) async throws -> UserMessage {
        let localID = localID(streamID: request.streamId)
        try Task.checkCancellation()
        switch action {
        case .question(let arguments):
            guard let askUser = request.askUser else { throw IDEToolError.notSupported("This turn cannot ask a question.") }
            let answer = try await askUser(.object(arguments))
            return UserMessage(toolUseId: localID, content: answer, isError: false)
        case .terminal(let command):
            return try await runTerminal(command, request: request, sessionID: sessionID, localID: localID, permission: permission)
        }
    }

    private func runTerminal(_ command: String, request: BackendSendRequest, sessionID: String,
                             localID: String, permission: PermissionServer) async throws -> UserMessage {
        let decision = await permission.requestDesktopShellDecision(id: localID, sessionId: sessionID,
                                                                   command: command, mode: request.permissionMode)
        try Task.checkCancellation()
        guard decision == .allow else {
            return UserMessage(toolUseId: localID, content: "The user denied this command.", isError: true)
        }

        do {
            let result = try await HarnessTerminalManager().run(
                command, workingDirectory: URL(fileURLWithPath: request.cwd, isDirectory: true),
                timeout: ShellTool.defaultTimeout, onOutput: { _, _ in }
            )
            try Task.checkCancellation()
            var output = result.output
            if let path = result.fullOutputPath { output += "\nFull output saved to \(path)." }
            if result.timedOut { output += "\nCommand timed out." }
            else if let code = result.exitCode, code != 0 { output += "\nExit code: \(code)" }
            else if result.exitCode == nil { output += "\nCommand was terminated." }
            return UserMessage(toolUseId: localID, content: output.isEmpty ? "(no output)" : output,
                               isError: result.timedOut || result.exitCode != 0)
        } catch {
            try Task.checkCancellation()
            return UserMessage(toolUseId: localID, content: "Could not run the command: \(error)", isError: true)
        }
    }
}
