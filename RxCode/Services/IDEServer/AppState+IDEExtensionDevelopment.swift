import Foundation
import ExtensionFoundation
import RxCodeCore

struct ExtensionEnablementRequest: Identifiable {
    let id = UUID()
    let name: String
    let sessionKey: String
}

extension AppState {
    func waitForExtensionEnablement(name: String, sessionKey: String, turnID: UUID,
                                    isEnabled: @MainActor () -> Bool) async throws {
        let request = ExtensionEnablementRequest(name: name, sessionKey: sessionKey)
        extensionEnablementRequests.append(request)
        defer { extensionEnablementRequests.removeAll { $0.id == request.id } }
        while true {
            try Task.checkCancellation()
            guard try extensionDevelopmentTurn(for: sessionKey).id == turnID else { throw CancellationError() }
            guard extensionEnablementRequests.contains(where: { $0.id == request.id }) else {
                throw IDEToolError.handlerFailed("The user cancelled enablement of \(name).")
            }
            if isEnabled() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func extensionDevelopmentTurn(for sessionKey: String) throws -> (id: UUID, workspace: URL) {
        guard let state = sessionStates[resolveCurrentSessionId(sessionKey)],
              state.isStreaming, !state.planMode, state.permissionMode != .plan,
              let streamID = state.activeStreamId,
              let workspace = extensionDevelopmentWorkspaces[streamID] else {
            throw IDEToolError.notSupported("Use extension development tools from an active project chat outside plan mode.")
        }
        return (streamID, workspace)
    }

    func handleExtensionDevelopmentTool(_ tool: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        if tool == "ide__list_extensions" {
            guard arguments.objectValue?.isEmpty == true else { throw IDEToolError.invalidArguments("Pass an empty object.") }
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .workspaceServices)
            try await monitor.addAppExtensionPoint(.workspaceContributions)
            let rows = monitor.identities.sorted { $0.bundleIdentifier < $1.bundleIdentifier }.map {
                ["bundleIdentifier": $0.bundleIdentifier, "name": $0.localizedName]
            }
            return textResult(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
        }
        let turn = try extensionDevelopmentTurn(for: sessionKey)
        let workspace = turn.workspace
        guard let fields = arguments.objectValue, let name = fields["name"]?.stringValue else {
            throw IDEToolError.invalidArguments("Pass the project-local extension name.")
        }
        let development = AgentExtensionDevelopment.shared
        switch tool {
        case "ide__create_extension":
            guard fields.count == 1 else { throw IDEToolError.invalidArguments("Pass only name.") }
            return textResult(try await development.create(workspace: workspace, name: name))
        case "ide__reload_extension":
            guard fields.keys.allSatisfy({ ["name", "signing_identity"].contains($0) }),
                  fields["signing_identity"] == nil || fields["signing_identity"]?.stringValue != nil else {
                throw IDEToolError.invalidArguments("Pass name and an optional signing_identity string.")
            }
            let identity = try await AgentExtensionBuilder.resolveSigningIdentity(
                in: workspace, name: name, requested: fields["signing_identity"]?.stringValue
            )
            guard try extensionDevelopmentTurn(for: sessionKey).id == turn.id else { throw CancellationError() }
            let confirmed = await requestAgentConfirmation(.init(
                title: "Sign and load \(name)?",
                message: "RxCode will build the extension in \(workspace.path), sign it using \(identity), and load it for testing.",
                confirmLabel: "Sign and Load"
            ), sessionKey: sessionKey)
            guard confirmed else { throw IDEToolError.handlerFailed("The user cancelled the extension reload.") }
            try Task.checkCancellation()
            guard try extensionDevelopmentTurn(for: sessionKey).id == turn.id else { throw CancellationError() }
            let result = try await development.reload(workspace: workspace, name: name, signingIdentity: identity, appState: self) { isEnabled in
                try await self.waitForExtensionEnablement(name: name, sessionKey: sessionKey, turnID: turn.id, isEnabled: isEnabled)
            }
            return textResult(result)
        case "ide__test_extension":
            guard fields.count == 2, let input = fields["input"]?.stringValue else {
                throw IDEToolError.invalidArguments("Pass name and an input string.")
            }
            return textResult(try await development.test(workspace: workspace, name: name, input: input))
        default:
            throw IDEToolError.unknownTool(tool)
        }
    }
}
