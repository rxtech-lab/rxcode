import Foundation

// MARK: - Transport / Scope

public enum MCPTransport: String, Codable, Sendable, CaseIterable, Identifiable {
    case stdio
    case http
    case sse

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stdio: return "stdio"
        case .http:  return "HTTP"
        case .sse:   return "SSE"
        }
    }
}

public enum MCPScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case user
    case project
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .user:    return "User"
        case .project: return "Project"
        case .local:   return "Local"
        }
    }

    public var subtitle: String {
        switch self {
        case .user:    return "Available in all projects"
        case .project: return "Shared via .mcp.json"
        case .local:   return "This project, this machine only"
        }
    }
}

public enum MCPProjectOverride: String, Codable, Sendable, CaseIterable, Identifiable {
    case inherit
    case enabled
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inherit: return "Inherit"
        case .enabled: return "On"
        case .disabled: return "Off"
        }
    }
}

public enum MCPProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode
    case codex

    public var id: String { rawValue }
}

// MARK: - Status

public enum MCPStatus: Sendable, Equatable {
    case connected
    case needsAuth
    case failed(String)
    case unknown

    public var label: String {
        switch self {
        case .connected:        return "Connected"
        case .needsAuth:        return "Needs authentication"
        case .failed(let msg):  return msg.isEmpty ? "Failed" : "Failed: \(msg)"
        case .unknown:          return "Unknown"
        }
    }
}

// MARK: - Listing / Detail

public struct MCPServerInfo: Identifiable, Sendable, Equatable, Hashable {
    public var id: String {
        if let projectPath, !projectPath.isEmpty {
            return "\(scope?.rawValue ?? "user"):\(projectPath):\(name)"
        }
        return "\(scope?.rawValue ?? "user"):\(name)"
    }
    public let name: String
    public let transport: MCPTransport
    public let endpoint: String   // url for http/sse, command line for stdio
    public let status: MCPStatus
    public var scope: MCPScope?
    public var projectPath: String?
    public var isGloballyEnabled: Bool
    public var projectOverride: MCPProjectOverride
    public var effectiveEnabled: Bool

    public init(
        name: String,
        transport: MCPTransport,
        endpoint: String,
        status: MCPStatus,
        scope: MCPScope? = nil,
        projectPath: String? = nil,
        isGloballyEnabled: Bool = true,
        projectOverride: MCPProjectOverride = .inherit,
        effectiveEnabled: Bool = true
    ) {
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.status = status
        self.scope = scope
        self.projectPath = projectPath
        self.isGloballyEnabled = isGloballyEnabled
        self.projectOverride = projectOverride
        self.effectiveEnabled = effectiveEnabled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct MCPServerDetail: Sendable, Equatable {
    public let name: String
    public let scope: MCPScope
    public let transport: MCPTransport
    public let url: String?
    public let command: String?
    public let args: [String]
    public let env: [String: String]
    public let headers: [String: String]
    public let projectPath: String?

    public init(name: String, scope: MCPScope, transport: MCPTransport, url: String?, command: String?, args: [String], env: [String: String], headers: [String: String] = [:], projectPath: String? = nil) {
        self.name = name
        self.scope = scope
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.projectPath = projectPath
    }
}

// MARK: - User-supplied spec

public struct MCPServerSpec: Sendable, Equatable {
    public var name: String
    public var transport: MCPTransport
    public var url: String
    public var headers: [MCPKeyValue]
    public var command: String
    public var args: [String]
    public var env: [MCPKeyValue]

    public init(
        name: String = "",
        transport: MCPTransport = .stdio,
        url: String = "",
        headers: [MCPKeyValue] = [],
        command: String = "",
        args: [String] = [],
        env: [MCPKeyValue] = []
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
    }
}

public struct MCPServerRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var transport: MCPTransport
    public var url: String?
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var headers: [String: String]
    public var cwd: String?
    public var bearerTokenEnvVar: String?
    public var isGloballyEnabled: Bool
    public var projectOverrides: [String: MCPProjectOverride]

    public init(
        name: String,
        transport: MCPTransport,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        headers: [String: String] = [:],
        cwd: String? = nil,
        bearerTokenEnvVar: String? = nil,
        isGloballyEnabled: Bool = true,
        projectOverrides: [String: MCPProjectOverride] = [:]
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.cwd = cwd
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.isGloballyEnabled = isGloballyEnabled
        self.projectOverrides = projectOverrides
    }

    public func projectOverride(for projectPath: String?) -> MCPProjectOverride {
        guard let projectPath, !projectPath.isEmpty else { return .inherit }
        return projectOverrides[projectPath] ?? .inherit
    }

    public func isEnabled(for projectPath: String?) -> Bool {
        switch projectOverride(for: projectPath) {
        case .inherit: return isGloballyEnabled
        case .enabled: return true
        case .disabled: return false
        }
    }
}

public struct MCPConfiguration: Codable, Sendable, Equatable {
    public var version: Int
    public var servers: [MCPServerRecord]

    public init(version: Int = 1, servers: [MCPServerRecord] = []) {
        self.version = version
        self.servers = servers
    }
}

public struct MCPKeyValue: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

// MARK: - Probe result

public struct MCPProbeResult: Sendable, Equatable {
    public let ok: Bool
    public let serverName: String?
    public let serverVersion: String?
    public let tools: [MCPTool]
    public let error: String?

    public init(ok: Bool, serverName: String? = nil, serverVersion: String? = nil, tools: [MCPTool] = [], error: String? = nil) {
        self.ok = ok
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.tools = tools
        self.error = error
    }
}

public struct MCPTool: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let description: String?

    public init(name: String, description: String?) {
        self.name = name
        self.description = description
    }
}
