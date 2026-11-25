import Foundation
import os
import RxCodeCore

/// Runs GUI tasks through the open-source cua computer-use agent
/// (github.com/trycua/cua) for agents whose model can't drive the screen
/// itself. RxCode talks to its MCP server (`cua-mcp-server`) over stdio and
/// starts the host computer server it uses to see and control this Mac.
actor OpenSourceComputerUseAgent {
    static let shared = OpenSourceComputerUseAgent()

    nonisolated static let serverCommandKey = "agentCUAServerCommand"
    nonisolated static let hostServerCommandKey = "agentCUAHostServerCommand"
    nonisolated static let startsHostServerKey = "agentCUAStartsHostServer"
    nonisolated static let defaultServerCommand = "uv tool run cua-mcp-server"
    nonisolated static let defaultHostServerCommand = "uv tool run cua-computer-server --host 127.0.0.1"
    /// Longest a single delegated task may run.
    nonisolated static let taskTimeoutSeconds = 900

    private struct Configuration: Equatable {
        let serverCommand: String
        let model: String
    }

    private var connection: MCPAppConnection?
    private var configuration: Configuration?
    private var hostServer: Process?
    /// One GUI task at a time: the screen and the MCP connection are shared.
    private var isBusy = false
    private let logger = Logger(subsystem: "com.claudework", category: "OpenSourceCUA")

    nonisolated static var serverCommand: String {
        let value = UserDefaults.standard.string(forKey: serverCommandKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultServerCommand : value
    }

    nonisolated static var hostServerCommand: String {
        let value = UserDefaults.standard.string(forKey: hostServerCommandKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultHostServerCommand : value
    }

    nonisolated static var startsHostServer: Bool {
        UserDefaults.standard.object(forKey: startsHostServerKey) as? Bool ?? true
    }

    /// Runs one GUI task and returns the MCP tool result.
    func run(task: String, model: String) async throws -> JSONValue {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IDEToolError.invalidArguments("Pass a task.") }
        while isBusy {
            try await Task.sleep(for: .milliseconds(250))
        }
        isBusy = true
        defer { shutdown(); isBusy = false }
        let configuration = Configuration(serverCommand: Self.serverCommand, model: model)
        if self.configuration != configuration {
            connection = nil
            self.configuration = configuration
        }
        if Self.startsHostServer { try await ensureHostServer() }
        let connection = try await makeConnection(configuration)
        let tools = try await connection.nativeToolDescriptors()
        let names = tools.compactMap { $0["name"]?.stringValue }
        guard let toolName = names.first(where: { $0 == "run_cua_task" })
            ?? names.first(where: { $0.contains("task") && !$0.contains("multi") }) else {
            throw IDEToolError.handlerFailed("The cua MCP server exposes no task tool (found: \(names.joined(separator: ", "))). Verify that cua-mcp-server is installed.")
        }
        logger.info("[CUA] running task with tool=\(toolName, privacy: .public) model=\(model, privacy: .public)")
        do {
            // The connection unwraps the JSON-RPC envelope and throws on errors.
            return try await connection.callNativeTool(toolName, arguments: ["task": .string(trimmed)])
        } catch {
            // A broken process is rebuilt on the next task.
            self.connection = nil
            throw error
        }
    }

    /// Stops the MCP and host servers, e.g. when RxCode quits.
    func shutdown() {
        connection = nil
        if let hostServer, hostServer.isRunning { hostServer.terminate() }
        hostServer = nil
    }

    private func makeConnection(_ configuration: Configuration) async throws -> MCPAppConnection {
        if let connection { return connection }
        let parts = Self.tokenize(configuration.serverCommand)
        guard let command = parts.first else {
            throw IDEToolError.handlerFailed("Configure the cua MCP server command.")
        }
        var env: [String: String] = [
            "CUA_MODEL_NAME": configuration.model,
            "CUA_USE_HOST_COMPUTER_SERVER": "true",
        ]
        if let path = await ShellPathResolver.shared.current() { env["PATH"] = path }
        let detail = MCPServerDetail(
            name: "cua", scope: .user, transport: .stdio, url: nil,
            command: command, args: Array(parts.dropFirst()), env: env
        )
        let connection = MCPAppConnection(detail: detail, timeoutSeconds: Self.taskTimeoutSeconds)
        self.connection = connection
        return connection
    }

    /// Starts `computer_server`, which the cua agent uses to see and control
    /// this Mac, for the duration of the delegated task.
    private func ensureHostServer() async throws {
        if let hostServer, hostServer.isRunning { return }
        if await Self.hostServerResponds() { return }
        let parts = Self.tokenize(Self.hostServerCommand)
        guard let command = parts.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + parts.dropFirst()
        var environment = ProcessInfo.processInfo.environment
        if let path = await ShellPathResolver.shared.current() { environment["PATH"] = path }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw IDEToolError.handlerFailed("Could not start the cua host computer server (\(Self.hostServerCommand)): \(error.localizedDescription)")
        }
        hostServer = process
        // First start may install packages; wait until it answers.
        for _ in 0..<60 {
            if await Self.hostServerResponds() { return }
            guard process.isRunning else { break }
            try await Task.sleep(for: .seconds(1))
        }
        throw IDEToolError.handlerFailed("The cua host computer server did not become ready on localhost:8000. Check that uv can launch cua-computer-server.")
    }

    private static func hostServerResponds() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8000/status") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["status"] as? String == "ok" && body["os_type"] != nil
    }

    /// Splits a command line on whitespace, honouring single and double quotes.
    nonisolated static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in line {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken || !current.isEmpty { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken || !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
