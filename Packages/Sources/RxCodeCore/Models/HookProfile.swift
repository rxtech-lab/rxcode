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

/// A single project-scoped automation that runs a command at a session
/// lifecycle point. Mirrors `RunProfile` one-to-one: it carries the same
/// `RunProfileType` and per-type config structs so a hook can run a bash
/// command, an `xcodebuild` invocation, a `make` target, or a package script.
/// The only hook-specific fields are `enabled` and the lifecycle `trigger`.
public struct HookProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: HookTrigger
    public var type: RunProfileType
    public var bash: BashRunConfig
    /// Populated when `type == .xcode`. Optional so hooks written before the
    /// typed configs existed (bash-only) decode cleanly.
    public var xcode: XcodeRunConfig?
    /// Populated when `type == .make`. Optional for backward-compatible decode.
    public var make: MakeRunConfig?
    /// Populated when `type == .packageScript`. Optional for backward-compatible decode.
    public var package: PackageRunConfig?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        enabled: Bool = true,
        trigger: HookTrigger = .beforeSessionStart,
        type: RunProfileType = .bash,
        bash: BashRunConfig = BashRunConfig(),
        xcode: XcodeRunConfig? = nil,
        make: MakeRunConfig? = nil,
        package: PackageRunConfig? = nil,
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
        self.xcode = xcode
        self.make = make
        self.package = package
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Bridge to `RunProfile` so a hook can reuse the run-profile command
    /// synthesis (`RunTaskExecutor.mainCommandLines`). Hooks have no
    /// before/after steps, so those are left empty.
    public var asRunProfile: RunProfile {
        RunProfile(
            id: id,
            projectId: projectId,
            name: name,
            type: type,
            bash: bash,
            xcode: xcode,
            make: make,
            package: package,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
