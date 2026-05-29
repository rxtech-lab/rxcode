import Foundation

/// Lifecycle point at which a hook fires.
public enum HookTrigger: String, Codable, Sendable, CaseIterable, Hashable {
    /// Fires once, when a brand-new thread begins its first turn. The hook's
    /// stdout is injected into the agent's context for that turn.
    case beforeSessionStart
    /// Fires when streaming stops, before the thread is finalized. The hook's
    /// output is shown and saved as a context block in the thread.
    case beforeSessionStop
    /// Fires after the thread is finalized/saved when streaming stops. The
    /// hook's output is shown only — nothing is passed back to the session.
    case afterSessionStop

    public var displayName: String {
        switch self {
        case .beforeSessionStart: return "Before Session Start"
        case .beforeSessionStop: return "Before Session Stop"
        case .afterSessionStop: return "After Session Stop"
        }
    }
}

/// What a hook runs. Bash-only today; typed so other kinds can be added later.
public enum HookType: String, Codable, Sendable, CaseIterable, Hashable {
    case bash
}

/// A single project-scoped automation that runs a command at a session
/// lifecycle point. Modeled on `RunProfile`; reuses `BashRunConfig` for the
/// command, working directory, and environment presets.
public struct HookProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: HookTrigger
    public var type: HookType
    public var bash: BashRunConfig
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        enabled: Bool = true,
        trigger: HookTrigger = .beforeSessionStart,
        type: HookType = .bash,
        bash: BashRunConfig = BashRunConfig(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.type = type
        self.bash = bash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
