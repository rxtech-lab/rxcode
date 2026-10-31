import Foundation
import RxAgentCore
import RxAgentHarness
import RxCodeCore

/// Builds the backend for `AgentProvider.localAgent`: RxAgentHarness running
/// on native MLX or the managed GGUF `llama-server`, behind the same
/// `SDKAgentBackend` bridge the SDK-backed Claude/Codex/ACP clients use.
enum LocalAgentBackendFactory {
    static let clientID: AgentClientID = "rx-local-agent"

    enum ResolveError: LocalizedError {
        case noModel
        case noRuntime(LocalModelWeightFormat)

        var errorDescription: String? {
            switch self {
            case .noModel: "No local model is installed. Download one in Settings → Agent → RxCode Agent."
            case .noRuntime(let format): "The \(format.runtimeName) runtime is not installed. Install it in Settings → Agent → RxCode Agent."
            }
        }
    }

    /// Built once: the backend holds the harness, whose per-session runtimes
    /// (permission approvals, background shells) must survive between turns.
    @MainActor private static var cached: (server: ObjectIdentifier, backend: any AgentBackend)?

    @MainActor
    static func backend(permissionServer: PermissionServer, store: LocalModelStore) -> any AgentBackend {
        if let cached, cached.server == ObjectIdentifier(permissionServer) { return cached.backend }
        let backend = makeBackend(permissionServer: permissionServer, store: store)
        cached = (ObjectIdentifier(permissionServer), backend)
        return backend
    }

    /// The SDK estimates the unabridged tool catalog. Local adapters check the
    /// prepared prompt instead and use the harness's overflow compaction path.
    static func configuration(store: any HarnessSessionStore) -> HarnessConfiguration {
        HarnessConfiguration(
            tools: HarnessToolset.standard(), store: store,
            systemPrompt: HarnessSystemPrompt(agentName: "RxCode"),
            compaction: HarnessCompactionPolicy(automatic: false)
        )
    }

    static func makeBackend(permissionServer: PermissionServer, store: LocalModelStore) -> any AgentBackend {
        let sessions = RxCodeHarnessSessionStore(
            directory: store.appSupport.appending(path: "harness-sessions")
        )
        let agent = HarnessAgent(configuration: configuration(store: sessions))
        let manager = store.manager

        let client = HarnessAgentClient(
            id: clientID,
            displayName: "RxCode Agent",
            agent: agent,
            models: {
                await MainActor.run {
                    store.installed.map { AgentModelOption(id: $0.id, displayName: $0.displayName) }
                }
            },
            resolveModel: { requested in
                let (model, root, context) = await MainActor.run {
                    (store.model(id: requested), store.modelsRoot, store.effectiveContextSize)
                }
                guard let model else { throw ResolveError.noModel }
                if model.format == .mlx {
                    guard LlamaRuntimeInstaller.isAppleSilicon else { throw MLXRuntimeInstaller.InstallError.unsupportedMac }
                    return .init(model: NativeMLXHarnessModel(manager: manager, model: model,
                        modelsRoot: root, contextWindow: min(context, model.contextLength ?? context)), name: model.id)
                }
                guard let runtime = await MainActor.run(body: { store.runtime(for: model.format) }) else {
                    throw ResolveError.noRuntime(model.format)
                }
                let server = try await manager.ensureServer(
                    for: model, modelsRoot: root, runtime: URL(filePath: runtime.path), contextSize: context
                )
                return .init(
                    model: LocalLlamaHarnessModel(
                        base: OpenAICompatibleHarnessModel(baseURL: server.baseURL, contextWindow: server.contextSize),
                        manager: manager
                    ),
                    name: model.id
                )
            }
        )

        return SDKAgentBackend(
            provider: .localAgent,
            capabilities: RxCodeCore.AgentProvider.localAgent.staticCapabilities,
            permissionServer: permissionServer,
            resolveClient: { _ in .init(client) }
        )
    }
}

/// Harness sessions live in RxCode's Application Support folder next to the
/// rest of its data. RxCode separately keeps the rendered chat in its own
/// thread store; this is the model-facing history (tool calls paired with
/// results, compaction checkpoints) the harness replays each turn.
actor RxCodeHarnessSessionStore: HarnessSessionStore {
    private let files: FileHarnessSessionStore

    init(directory: URL) {
        files = FileHarnessSessionStore(directory: directory)
    }

    func load(id: String) async throws -> HarnessSession? { try await files.load(id: id) }
    func save(_ session: HarnessSession) async throws { try await files.save(session) }
    func delete(id: String) async throws { try await files.delete(id: id) }
    func list() async throws -> [HarnessSessionInfo] { try await files.list() }
}
