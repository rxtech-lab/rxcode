import Foundation

/// Catalog of IDE-side MCP tools the editor can expose to agent backends.
/// Tools are gated by the *complement* of the backend's capability set:
/// if a backend natively supports a feature, the corresponding polyfill
/// tool is NOT registered for that session. Tools tagged `.alwaysIDEOnly`
/// are exposed to every backend regardless of capabilities, including
/// IDE state and prompts that must remain available in every agent mode.
public struct IDETool: Sendable {
    public enum Visibility: Sendable {
        /// Exposed only when the backend lacks the matched capability.
        case polyfill(BackendCapability)
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
