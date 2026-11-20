import Foundation

/// Catalog of IDE-side MCP tools the editor can expose to agent backends.
/// Polyfills are available to backends that lack the native capability and to
/// providers that opt into the IDE implementation. IDE-only tools are always
/// available, including IDE state and prompts used in every agent mode.
public struct IDETool: Sendable {
    public enum Visibility: Sendable {
        /// Exposed when the backend lacks the capability or the provider is listed.
        case polyfill(BackendCapability, alsoFor: Set<AgentProvider> = [])
        /// Exposed unconditionally, independent of native tools or agent mode.
        case alwaysIDEOnly
    }

    public let name: String
    public let description: String
    public let visibility: Visibility
    /// JSON Schema for the tool's input parameters, serialized as a
    /// `JSONValue` object. Consumed by the MCP server's `tools/list` handler.
    public let inputSchema: JSONValue

    public init(name: String, description: String, visibility: Visibility, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.visibility = visibility
        self.inputSchema = inputSchema
    }
}
