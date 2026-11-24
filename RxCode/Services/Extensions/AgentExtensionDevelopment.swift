import Foundation

/// Coordinates builds across chat sessions sharing a worktree. Each extension
/// has one installed container, so two reloads must not publish over each other.
actor AgentExtensionDevelopment {
    static let shared = AgentExtensionDevelopment()
    private var reloading: Set<String> = []

    func create(workspace: URL, name: String) throws -> String {
        let file = try AgentExtensionBuilder.create(in: workspace, name: name)
        let folder = file.deletingLastPathComponent().path
        return "Created \(file.path) and \(folder)/README.md. Edit the Swift test handler and the README. Optionally add a square PNG at \(folder)/icon.png. Then call ide__reload_extension with name '\(name)'."
    }

    func reload(workspace: URL, name: String, signingIdentity: String?,
                requestEnablement: ExtensionEnablementHandler) async throws -> String {
        let identifier = try AgentExtensionBuilder.serviceIdentifier(in: workspace, name: name)
        guard reloading.insert(identifier).inserted else { throw DevelopmentError.reloadInProgress(name) }
        defer { reloading.remove(identifier) }

        let build = try await AgentExtensionBuilder.build(in: workspace, name: name, signingIdentity: signingIdentity)
        try Task.checkCancellation()
        try await AgentExtensionRuntime.shared.reload(
            workspace: workspace,
            bundleIdentifier: build.bundleIdentifier,
            container: build.containerURL,
            generation: build.generation,
            requestEnablement: requestEnablement
        )
        return "Loaded \(name) (build \(build.generation), plugin API \(ExtensionPluginAPI.version)). Call ide__test_extension with name '\(name)' and a text input."
    }

    func test(workspace: URL, name: String, input: String) async throws -> String {
        let identifier = try AgentExtensionBuilder.serviceIdentifier(in: workspace, name: name)
        guard !reloading.contains(identifier) else { throw DevelopmentError.reloadInProgress(name) }
        return try await AgentExtensionRuntime.shared.test(workspace: workspace, bundleIdentifier: identifier, input: input)
    }

    private enum DevelopmentError: LocalizedError {
        case reloadInProgress(String)

        var errorDescription: String? {
            switch self {
            case .reloadInProgress(let name): "Wait for the current reload of '\(name)' to finish and try again."
            }
        }
    }
}
