import Foundation

// MARK: - Registry Schema
// Mirrors the JSON schema served at
// https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json

public struct ACPRegistry: Codable, Sendable {
    public var version: String
    public var agents: [ACPRegistryAgent]
    public var extensions: [ACPRegistryExtension]?

    public init(version: String, agents: [ACPRegistryAgent], extensions: [ACPRegistryExtension]? = nil) {
        self.version = version
        self.agents = agents
        self.extensions = extensions
    }
}

public struct ACPRegistryAgent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var repository: String?
    public var website: String?
    public var authors: [String]?
    public var license: String?
    public var icon: String?
    public var distribution: ACPDistribution

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        repository: String? = nil,
        website: String? = nil,
        authors: [String]? = nil,
        license: String? = nil,
        icon: String? = nil,
        distribution: ACPDistribution
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.repository = repository
        self.website = website
        self.authors = authors
        self.license = license
        self.icon = icon
        self.distribution = distribution
    }
}

public struct ACPRegistryExtension: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var description: String?
}

public struct ACPDistribution: Codable, Hashable, Sendable {
    public var npx: ACPNpxDist?
    public var uvx: ACPUvxDist?
    /// Keyed by platform: darwin-aarch64, darwin-x86_64, linux-*, windows-*
    public var binary: [String: ACPBinaryDist]?

    public init(npx: ACPNpxDist? = nil, uvx: ACPUvxDist? = nil, binary: [String: ACPBinaryDist]? = nil) {
        self.npx = npx
        self.uvx = uvx
        self.binary = binary
    }
}

public struct ACPNpxDist: Codable, Hashable, Sendable {
    public var package: String
    public var args: [String]?
    public var env: [String: String]?
}

public struct ACPUvxDist: Codable, Hashable, Sendable {
    public var package: String
    public var args: [String]?
    public var env: [String: String]?
}

public struct ACPBinaryDist: Codable, Hashable, Sendable {
    public var archive: String
    public var cmd: String
    public var args: [String]?
    public var env: [String: String]?
}

// MARK: - Installed Client

/// User-installed instance of an ACP agent. Persisted to
/// `Application Support/RxCode/acp_clients.json`.
public struct ACPClientSpec: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// `ACPRegistryAgent.id` this was installed from (if any).
    public var registryId: String?
    public var displayName: String
    public var enabled: Bool
    /// Method by which this client is launched.
    public var launch: LaunchKind
    /// Model IDs surfaced in the model picker. Populated by probing the agent
    /// at install time (and refreshed on every session start), with manual
    /// entry as a fallback for agents that don't advertise a model selector.
    public var models: [String]
    /// Full model options advertised by the ACP client. `models` is kept as a
    /// lightweight compatibility list of option values, while this stores the
    /// human-readable names shown in the picker.
    public var modelOptions: [ACPModelOption]?
    /// `SessionConfigId` of the model selector exposed by the agent's
    /// `session/new` response. Present iff the agent advertises a
    /// `category: "model"` config option; used to issue
    /// `session/set_config_option` for live model switching.
    public var modelConfigId: String?
    /// Env var the agent reads the model ID from (e.g. `ANTHROPIC_MODEL`).
    /// When set, RxCode sets this var to the selected model at spawn time.
    /// Used as a fallback for agents that don't expose `modelConfigId`.
    public var modelEnvVar: String?
    public var extraEnv: [String: String]
    public var extraArgs: [String]
    public var iconURL: String?

    public init(
        id: String = UUID().uuidString,
        registryId: String? = nil,
        displayName: String,
        enabled: Bool = true,
        launch: LaunchKind,
        models: [String] = [],
        modelOptions: [ACPModelOption]? = nil,
        modelConfigId: String? = nil,
        modelEnvVar: String? = nil,
        extraEnv: [String: String] = [:],
        extraArgs: [String] = [],
        iconURL: String? = nil
    ) {
        self.id = id
        self.registryId = registryId
        self.displayName = displayName
        self.enabled = enabled
        self.launch = launch
        self.models = models
        self.modelOptions = modelOptions
        self.modelConfigId = modelConfigId
        self.modelEnvVar = modelEnvVar
        self.extraEnv = extraEnv
        self.extraArgs = extraArgs
        self.iconURL = iconURL
    }

    public enum LaunchKind: Codable, Hashable, Sendable {
        /// Run via `npx -y <package>` (Node required on PATH).
        case npx(package: String, args: [String], env: [String: String])
        /// Run via `uvx <package>` (uv required on PATH).
        case uvx(package: String, args: [String], env: [String: String])
        /// Run a binary already on disk at `path`.
        case binary(path: String, args: [String], env: [String: String])
        /// Run an arbitrary user-supplied command.
        case custom(command: String, args: [String], env: [String: String])

        public var displayKind: String {
            switch self {
            case .npx: return "npx"
            case .uvx: return "uvx"
            case .binary: return "binary"
            case .custom: return "custom"
            }
        }
    }
}

// MARK: - Platform Helpers

public enum ACPPlatform {
    /// Returns the registry platform key matching the running host, or nil if unsupported.
    public static var current: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #elseif arch(x86_64)
        return "darwin-x86_64"
        #else
        return "darwin-unknown"
        #endif
    }
}

// MARK: - Model Discovery

/// A single model exposed by an agent's `session/new` configOptions entry.
/// Mirrors `SessionConfigSelectOption` in the ACP schema.
public struct ACPModelOption: Codable, Hashable, Sendable {
    /// `SessionConfigValueId` — the model id passed back to
    /// `session/set_config_option`.
    public var value: String
    /// Human-readable label.
    public var name: String
    public var description: String?

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }
}

/// Model selector discovered from an agent's `session/new` response — a
/// `SessionConfigOption` with `category: "model"` and `type: "select"`.
public struct ACPModelConfig: Codable, Hashable, Sendable {
    /// `SessionConfigId` used to switch the model via
    /// `session/set_config_option`.
    public var configId: String
    public var currentValue: String?
    public var options: [ACPModelOption]

    public init(configId: String, currentValue: String? = nil, options: [ACPModelOption]) {
        self.configId = configId
        self.currentValue = currentValue
        self.options = options
    }
}
