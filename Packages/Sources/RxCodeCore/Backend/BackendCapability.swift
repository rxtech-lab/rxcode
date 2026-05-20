import Foundation

/// Editor-facing features an agent backend may natively support. A backend
/// that lacks a capability gets it polyfilled via the IDE-side MCP server
/// (Phase 2+) so the user-visible behavior is uniform across providers.
public enum BackendCapability: String, Sendable, Hashable, CaseIterable, Codable {
    case askUserQuestion
    case todos
    case planMode
    case fileEdit
    case getUsage
    case customSlashCommands
    case attachments
    case hooks
    case mcpServers
    case skills
}

public typealias CapabilitySet = Set<BackendCapability>

public extension AgentProvider {
    /// Compile-time defaults. Phase 1 ships with these; backends may later
    /// override at runtime via `AgentBackend.capabilities(for:)` once handshake
    /// negotiation lands (Phase 2+).
    var staticCapabilities: CapabilitySet {
        switch self {
        case .claudeCode:
            return [
                .askUserQuestion, .todos, .planMode, .fileEdit, .hooks,
                .mcpServers, .skills, .attachments, .customSlashCommands, .getUsage,
            ]
        case .codex:
            return [
                .askUserQuestion, .todos, .planMode, .fileEdit,
                .mcpServers, .skills, .attachments, .getUsage,
            ]
        case .acp:
            return [
                .planMode, .fileEdit, .mcpServers, .skills, .attachments, .getUsage,
            ]
        }
    }
}
