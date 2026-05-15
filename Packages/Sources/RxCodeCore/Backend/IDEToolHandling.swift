import Foundation

/// Anything that can serve IDE-side MCP tool calls. AppState conforms in
/// the host target so the bridge listener stays decoupled from UI state.
///
/// All entry points are isolated to the conforming actor; the bridge hops
/// to the actor before invoking. Handlers may freely touch UI state.
public protocol IDEToolHandling: AnyObject, Sendable {
    /// Tools exposed to the agent for `sessionKey`. The bridge calls this
    /// at `tools/list` time. Implementations typically derive the list from
    /// `IDEToolRegistry.tools(for:)` minus any per-session opt-outs.
    func ideAvailableTools(forSession sessionKey: String) async -> [IDETool]

    /// Dispatch a `tools/call`. Returns the tool result as a `JSONValue`
    /// (typically `.object(["content": .array([...]) ])` per the MCP spec)
    /// or throws an `IDEToolError`. The bridge translates throws into MCP
    /// error responses.
    func ideHandleToolCall(
        name: String,
        arguments: JSONValue,
        sessionKey: String
    ) async throws -> JSONValue
}

public enum IDEToolError: Error, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case notSupported(String)
    case handlerFailed(String)
}
