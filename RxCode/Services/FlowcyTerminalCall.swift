import Foundation
import RxAgentHarness
import RxCodeCore

/// Flowcy requests a foreground command. RxCode owns its working directory, approval and execution.
nonisolated struct FlowcyTerminalCall {
    static let name = "bash"
    static let definition: JSONValue = .object([
        "name": .string(name),
        "description": .string("Run a shell command on the user's Mac in the selected project or Git worktree and return its output."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object(["command": .object(["type": .string("string")])]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false),
        ]),
    ])

    let id: String
    let command: String
    var input: [String: JSONValue] { ["command": .string(command)] }

    init?(event: JSONValue) {
        guard event["name"]?.stringValue == Self.name,
              let id = event["id"]?.stringValue, !id.isEmpty,
              let arguments = event["arguments"]?.objectValue, arguments.count == 1,
              let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.utf8.contains(0) else { return nil }
        self.id = id
        self.command = command
    }

    // The permission queue is shared by all threads. Scope remote IDs to the local turn,
    // and preserve the provider's original ID for replay of completed call/result pairs.
    func localID(streamID: UUID) -> String { "flowcy:\(streamID.uuidString):\(id)" }

    init?(saved: ToolCall) {
        let parts = saved.id.split(separator: ":", maxSplits: 2)
        guard saved.name == "Bash", parts.count == 3, parts[0] == "flowcy",
              let command = saved.input["command"]?.stringValue else { return nil }
        id = String(parts[2])
        self.command = command
    }

    var callPart: JSONValue {
        .object(["type": .string("tool-call"), "toolCallId": .string(id),
                 "toolName": .string(Self.name), "input": .object(input)])
    }

    func resultPart(_ text: String, isError: Bool) -> JSONValue {
        .object(["type": .string("tool-result"), "toolCallId": .string(id), "toolName": .string(Self.name),
                 "output": .object(["type": .string(isError ? "error-text" : "text"), "value": .string(text)])])
    }

    func execute(request: BackendSendRequest, sessionID: String, permission: PermissionServer) async throws -> UserMessage {
        let localID = localID(streamID: request.streamId)
        try Task.checkCancellation()
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
