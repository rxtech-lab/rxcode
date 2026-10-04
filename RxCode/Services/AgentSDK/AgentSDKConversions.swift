import Foundation
import RxAgentCore
import RxCodeCore

// RxCodeCore and RxAgentCore both define `JSONValue`, `TodoItem`,
// `PermissionMode`, `PermissionRequest`, `PermissionDecision`, `UsageInfo`,
// `MCPServerSpec` and friends — the SDK was extracted from this app, so the
// shapes are the same and only the module differs. Rather than teach the whole
// app target to disambiguate, the `AgentSDK` folder is the one place that
// imports both, and it spells out which module it means every time.
//
// These conversions are mechanical and total: every case maps, so none of them
// can fail or need a default.

typealias SDKJSON = RxAgentCore.JSONValue
typealias AppJSON = RxCodeCore.JSONValue

// MARK: - JSON

extension AppJSON {
    init(_ value: SDKJSON) {
        switch value {
        case .string(let string): self = .string(string)
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .object(let object): self = .object(object.mapValues(AppJSON.init))
        case .array(let array): self = .array(array.map(AppJSON.init))
        case .null: self = .null
        }
    }
}

extension SDKJSON {
    init(_ value: AppJSON) {
        switch value {
        case .string(let string): self = .string(string)
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .object(let object): self = .object(object.mapValues(SDKJSON.init))
        case .array(let array): self = .array(array.map(SDKJSON.init))
        case .null: self = .null
        }
    }
}

// MARK: - Todos

extension RxCodeCore.TodoItem {
    init(_ item: RxAgentCore.TodoItem) {
        self.init(
            id: item.id,
            content: item.content,
            activeForm: item.activeForm,
            status: RxCodeCore.TodoItem.Status(rawValue: item.status.rawValue) ?? .pending
        )
    }
}

// MARK: - Permission mode

extension RxAgentCore.PermissionMode {
    init(_ mode: RxCodeCore.PermissionMode) {
        // Both enums are string-backed off the same CLI vocabulary, so the raw
        // value is the contract. A mode the SDK doesn't know is treated as
        // `.default`, which asks — the safe direction to fail in.
        self = RxAgentCore.PermissionMode(rawValue: mode.rawValue) ?? .default
    }
}

extension RxCodeCore.PermissionMode {
    init(_ mode: RxAgentCore.PermissionMode) {
        self = RxCodeCore.PermissionMode(rawValue: mode.rawValue) ?? .default
    }
}

// MARK: - Permission requests and decisions

extension RxCodeCore.PermissionRequest {
    /// Translate an SDK approval request into the one the existing sheet renders.
    ///
    /// `sessionId` and `runToken` are not part of the SDK request — the SDK
    /// identifies a conversation by its own `AgentThreadID` and holds the
    /// approval continuation itself, where RxCode keys both by its session key
    /// — so the caller supplies them.
    init(_ request: RxAgentCore.PermissionRequest, sessionId: String?, runToken: String) {
        self.init(
            id: request.id,
            toolName: request.toolName,
            toolInput: request.toolInput.mapValues(AppJSON.init),
            runToken: runToken,
            streamPermissionMode: RxCodeCore.PermissionMode(request.mode),
            sessionId: sessionId
        )
    }
}

extension RxAgentCore.PermissionDecision {
    /// RxCode's decisions are a strict subset of the SDK's — it has no
    /// `.allowWithInput`, because `AskUserQuestion` answers are injected
    /// through `AppState.respondToAskUserQuestion` rather than by rewriting the
    /// tool's input — so every case maps and nothing is lost.
    init(_ decision: RxCodeCore.PermissionDecision) {
        switch decision {
        case .allow: self = .allow
        case .deny: self = .deny
        case .allowSessionTool: self = .allowSessionTool
        case .allowAlwaysCommand(let command): self = .allowAlwaysCommand(command: command)
        case .allowAndSetMode(let mode): self = .allowAndSetMode(newMode: .init(mode))
        case .denyWithReason(let reason): self = .denyWithReason(reason: reason)
        }
    }
}

// MARK: - MCP servers

extension RxAgentCore.MCPServerSpec {
    /// Build the SDK's server description from RxCode's persisted record.
    ///
    /// Returns `nil` when the record is missing the field its transport needs —
    /// a stdio entry with no command, or an HTTP entry with an unparseable URL.
    /// Those are already unusable; passing them on would only move the failure
    /// into the agent.
    init?(_ record: MCPServerRecord) {
        let transport: Transport
        switch record.transport {
        case .stdio:
            guard let command = record.command, !command.isEmpty else { return nil }
            transport = .stdio(command: command, args: record.args, env: record.env)
        case .http:
            guard let string = record.url, let url = URL(string: string) else { return nil }
            transport = .http(url: url, headers: record.headers)
        case .sse:
            guard let string = record.url, let url = URL(string: string) else { return nil }
            transport = .sse(url: url, headers: record.headers)
        }
        self.init(name: record.name, transport: transport)
    }

    /// The in-app IDE MCP server, reached through its loopback stdio bridge.
    static func ideBridge(_ bridge: MCPBridgeCommand) -> RxAgentCore.MCPServerSpec {
        .stdio(name: "rxcode-ide", command: bridge.command, args: bridge.args)
    }
}

extension BackendSendRequest {
    /// Every MCP server this turn should expose, in the SDK's vocabulary.
    var sdkMCPServers: [RxAgentCore.MCPServerSpec] {
        var specs: [RxAgentCore.MCPServerSpec] = []
        if let ideBridgeCommand {
            specs.append(.ideBridge(ideBridgeCommand))
        }
        specs += mcpServers
            .sorted { $0.name < $1.name }
            .compactMap(RxAgentCore.MCPServerSpec.init)
        return specs
    }
}

extension RxCodeCore.ReasoningLevel {
    /// The SDK already carries display names and one-line descriptions for each
    /// level, so this is a rename rather than a lookup.
    init(_ option: RxAgentCore.AgentReasoningOption) {
        self.init(
            id: option.id,
            displayName: option.displayName,
            levelDescription: option.levelDescription
        )
    }
}
