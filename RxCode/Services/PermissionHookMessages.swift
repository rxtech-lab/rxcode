import Foundation
import RxCodeCore
import Network
import os

// MARK: - Request / Response Codables

/// The JSON body sent by the Claude CLI hook.
struct HookRequestBody: Decodable {
    let hookEventName: String
    let toolName: String
    let toolInput: [String: JSONValue]
    let toolUseId: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case sessionId = "session_id"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        toolName = try c.decode(String.self, forKey: .toolName)
        toolInput = try c.decode([String: JSONValue].self, forKey: .toolInput)
        toolUseId = try c.decode(String.self, forKey: .toolUseId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
    }
}

/// The JSON response body returned to the Claude CLI.
struct HookResponseBody: Encodable {
    let hookSpecificOutput: HookOutput

    struct HookOutput: Encodable {
        let hookEventName: String
        let permissionDecision: String
        let permissionDecisionReason: String
        /// When non-nil, the CLI replaces the original tool input with this value.
        /// Used for AskUserQuestion to inject the user's answers.
        let updatedInput: JSONValue?

        nonisolated func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(hookEventName, forKey: .hookEventName)
            try c.encode(permissionDecision, forKey: .permissionDecision)
            try c.encode(permissionDecisionReason, forKey: .permissionDecisionReason)
            if let updatedInput {
                try c.encode(updatedInput, forKey: .updatedInput)
            }
        }

        enum CodingKeys: String, CodingKey {
            case hookEventName, permissionDecision, permissionDecisionReason, updatedInput
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hookSpecificOutput, forKey: .hookSpecificOutput)
    }

    enum CodingKeys: String, CodingKey {
        case hookSpecificOutput
    }
}

// MARK: - Errors

enum PermissionServerError: LocalizedError {
    case noAvailablePort
    case connectionClosed
    case malformedRequest

    var errorDescription: String? {
        switch self {
        case .noAvailablePort: return "No available port in range 19836–19846"
        case .connectionClosed: return "Connection closed unexpectedly"
        case .malformedRequest: return "Malformed HTTP request"
        }
    }
}
