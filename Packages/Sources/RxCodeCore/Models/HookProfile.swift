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

/// What a hook *does* when it fires. `command` is the original behavior — run a
/// shell/build command (`type` + the per-type configs below). The other cases
/// are built-in automations that don't run a command at all and are restricted
/// to the session-stop lifecycle.
public enum HookAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// Run a `RunProfileType` command (bash / xcode / make / package).
    case command
    /// Send the change to a linked `[Code Review]` thread for review; a failing
    /// review feeds its notes back to the agent. Pairs with `.afterSessionStop`.
    case codeReview
    /// Instruct the agent to commit the changed files and push. Pairs with
    /// `.afterSessionStop`.
    case commitPush

    public var displayName: String {
        switch self {
        case .command: return "Command"
        case .codeReview: return "Code Review"
        case .commitPush: return "Commit & Push"
        }
    }

    /// The single lifecycle a built-in action is allowed to run at, or `nil`
    /// for `.command` (which supports every trigger).
    public var fixedTrigger: HookTrigger? {
        switch self {
        case .command: return nil
        case .codeReview: return .afterSessionStop
        case .commitPush: return .afterSessionStop
        }
    }
}

/// Per-hook configuration for the `.codeReview` action.
public struct CodeReviewConfig: Codable, Sendable, Hashable {
    /// Provider-qualified model key for the review thread (`<provider>:<model>`).
    /// Empty/`nil` ⇒ inherit the reviewed thread's model. Older bare model ids
    /// are still accepted by the app and resolved against the available model list.
    public var model: String?
    /// Optional extra guidance appended to the reviewer's prompt.
    public var instructions: String?

    public init(model: String? = nil, instructions: String? = nil) {
        self.model = model
        self.instructions = instructions
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
    /// What the hook does. Defaults to `.command` so hooks persisted before this
    /// field existed decode unchanged.
    public var action: HookAction
    public var type: RunProfileType
    public var bash: BashRunConfig
    /// Populated when `type == .xcode`. Optional so hooks written before the
    /// typed configs existed (bash-only) decode cleanly.
    public var xcode: XcodeRunConfig?
    /// Populated when `type == .make`. Optional for backward-compatible decode.
    public var make: MakeRunConfig?
    /// Populated when `type == .packageScript`. Optional for backward-compatible decode.
    public var package: PackageRunConfig?
    /// Populated when `action == .codeReview`. Optional for backward-compatible decode.
    public var codeReview: CodeReviewConfig?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        enabled: Bool = true,
        trigger: HookTrigger = .beforeSessionStart,
        action: HookAction = .command,
        type: RunProfileType = .bash,
        bash: BashRunConfig = BashRunConfig(),
        xcode: XcodeRunConfig? = nil,
        make: MakeRunConfig? = nil,
        package: PackageRunConfig? = nil,
        codeReview: CodeReviewConfig? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.type = type
        self.bash = bash
        self.xcode = xcode
        self.make = make
        self.package = package
        self.codeReview = codeReview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, enabled, trigger, action, type, bash, xcode, make, package, codeReview, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try container.decodeIfPresent(HookTrigger.self, forKey: .trigger) ?? .beforeSessionStart
        action = try container.decodeIfPresent(HookAction.self, forKey: .action) ?? .command
        type = try container.decodeIfPresent(RunProfileType.self, forKey: .type) ?? .bash
        bash = try container.decodeIfPresent(BashRunConfig.self, forKey: .bash) ?? BashRunConfig()
        xcode = try container.decodeIfPresent(XcodeRunConfig.self, forKey: .xcode)
        make = try container.decodeIfPresent(MakeRunConfig.self, forKey: .make)
        package = try container.decodeIfPresent(PackageRunConfig.self, forKey: .package)
        codeReview = try container.decodeIfPresent(CodeReviewConfig.self, forKey: .codeReview)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
