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

    /// Prints as its message, since the SDK formats failures with `String(describing:)`.
    struct ResolveFailure: LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

    /// Built once: the backend holds the harness, whose per-session runtimes
    /// (permission approvals, background shells) must survive between turns.
    @MainActor private static var cached: (server: ObjectIdentifier, backend: any AgentBackend)?

    /// The user's default task model, read when a video model first needs
    /// its companion files looked up; nil when none can run the lookup.
    typealias TaskModelProvider = @MainActor @Sendable () -> VideoCompanionResolver.TaskModel?

    @MainActor
    static func backend(
        permissionServer: PermissionServer, store: LocalModelStore, taskModel: @escaping TaskModelProvider = { nil }
    ) -> any AgentBackend {
        if let cached, cached.server == ObjectIdentifier(permissionServer) { return cached.backend }
        let backend = makeBackend(permissionServer: permissionServer, store: store, taskModel: taskModel)
        cached = (ObjectIdentifier(permissionServer), backend)
        return backend
    }

    /// The SDK estimates the unabridged tool catalog. Local adapters check the
    /// prepared prompt instead and use the harness's overflow compaction path.
    static func configuration(store: any HarnessSessionStore, extraTools: [any HarnessTool] = []) -> HarnessConfiguration {
        HarnessConfiguration(
            tools: HarnessToolset.standard() + extraTools, store: store,
            systemPrompt: HarnessSystemPrompt(agentName: "RxCode"),
            compaction: HarnessCompactionPolicy(automatic: false)
        )
    }

    /// Renders clips for whichever video model the turn's tool call names.
    static func videoTool(
        store: LocalModelStore, manager: LlamaServerManager, taskModel: @escaping TaskModelProvider
    ) -> VideoGenerationTool {
        VideoGenerationTool(job: { modelID in
            await MainActor.run {
                guard let model = store.model(id: modelID), LocalVideoRecipe.supports(model) else { return nil }
                let resolver = taskModel()
                return VideoGenerationTool.Job(
                    model: model, modelsRoot: store.modelsRoot, outputDirectory: store.generatedVideosRoot,
                    prepare: { report in
                        try await store.prepareVideoGeneration(model: model, taskModel: resolver, report: report)
                    }
                )
            }
        }, manager: manager)
    }

    static func makeBackend(
        permissionServer: PermissionServer, store: LocalModelStore, taskModel: @escaping TaskModelProvider = { nil }
    ) -> any AgentBackend {
        let sessions = RxCodeHarnessSessionStore(
            directory: store.appSupport.appending(path: "harness-sessions")
        )
        let manager = store.manager
        let agent = HarnessAgent(configuration: configuration(
            store: sessions, extraTools: [videoTool(store: store, manager: manager, taskModel: taskModel)]
        ))

        let resolve: HarnessAgentClient.ModelResolver = { requested in
            let (model, root, context) = await MainActor.run {
                (store.model(id: requested), store.modelsRoot, store.effectiveContextSize)
            }
            guard let model else { throw ResolveError.noModel }
            if model.isVideoModel {
                guard LocalVideoRecipe.supports(model) else {
                    throw ResolveFailure(message: "This is a video model, but RxCode does not yet support its video architecture.")
                }
                return .init(model: LocalVideoHarnessModel(modelID: model.id), name: model.id)
            }
            if model.format == .mlx {
                guard LlamaRuntimeInstaller.isAppleSilicon else { throw MLXRuntimeInstaller.InstallError.unsupportedMac }
                guard await MainActor.run(body: { store.runtime(for: .mlx) }) != nil else {
                    throw ResolveError.noRuntime(.mlx)
                }
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
                // The SDK reports resolver failures with `String(describing:)`,
                // which prints enum cases. Hand it the localized message instead.
                do { return try await resolve(requested) } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ResolveFailure(message: error.localizedDescription)
                }
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
