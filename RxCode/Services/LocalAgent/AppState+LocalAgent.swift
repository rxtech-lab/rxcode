import Foundation
import os
import RxCodeCore

extension AppState {
    /// Downloaded Hugging Face models and the llama.cpp server that runs them.
    var localModels: LocalModelStore { .shared }

    /// RxCode's own agent (RxAgentHarness) on a local model.
    var localAgentBackend: any AgentBackend {
        LocalAgentBackendFactory.backend(permissionServer: permission, store: localModels) { [weak self] kind in
            self?.studioSetupTaskModel(for: kind)
        }
    }

    /// The agent a studio uses to set up its models: the one picked in that
    /// studio's Setup menu, else the default task agent (Settings → Tasks).
    func studioSetupAgent(for kind: LocalStudioKind) -> TaskAgentConfig {
        LocalStudioPreferences.load(for: kind).setupAgent ?? defaultTaskAgent()
    }

    /// The studio's setup agent, as the companion lookups use it. nil when it
    /// is the local agent itself, which can't answer one-shot prompts.
    func studioSetupTaskModel(for kind: LocalStudioKind) -> VideoCompanionResolver.TaskModel? {
        let agent = studioSetupAgent(for: kind)
        guard (agent.provider ?? selectedAgentProvider) != .localAgent else { return nil }
        return VideoCompanionResolver.TaskModel(label: taskAgentLabel(agent)) { [weak self] prompt in
            await self?.runTaskAgentCompletion(prompt: prompt, projectId: nil, model: .agent(agent), verbatim: true)
        }
    }

    /// Builds a settings form for `modelID` from its README with the studio's
    /// setup agent. The caller saves it once the user accepts it.
    func generateStudioConfig(modelID: String, previous: StudioModelConfig?) async throws -> StudioModelConfig {
        guard let model = localModels.model(id: modelID) else {
            throw StudioConfigAgent.Failure(String(localized: "The model is no longer installed."))
        }
        guard let taskModel = studioSetupTaskModel(for: model.studioKind) else {
            throw StudioConfigAgent.Failure(String(localized: "Choose a setup agent in the studio's Engine & Setup settings first. RxCode's local agent can't read model cards."))
        }
        return try await StudioConfigAgent.generate(model: model, modelsRoot: localModels.modelsRoot,
                                                    taskModel: taskModel, previous: previous)
    }

    /// Builds and saves a freshly downloaded studio model's settings form in
    /// the background, so it is ready before the first generation. A failure
    /// leaves the model on its quality preset; the composer can retry.
    func generateStudioConfigAfterDownload(_ model: LocalModelInfo) {
        guard !StudioParameterKey.supported(for: model.studioKind).isEmpty,
              StudioModelConfig.load(modelID: model.id) == nil,
              !StudioModelConfig.isPending(modelID: model.id),
              let taskModel = studioSetupTaskModel(for: model.studioKind) else { return }
        StudioModelConfig.setPending(true, modelID: model.id)
        let modelsRoot = localModels.modelsRoot
        Task { [weak self] in
            defer { StudioModelConfig.setPending(false, modelID: model.id) }
            do {
                let config = try await StudioConfigAgent.generate(model: model, modelsRoot: modelsRoot, taskModel: taskModel)
                // The user may have generated one from the composer meanwhile.
                if StudioModelConfig.load(modelID: model.id) == nil { StudioModelConfig.save(config) }
            } catch {
                self?.logger.error("studio settings for \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The video studio's setup agent; kept for the video companion lookup.
    func videoCompanionTaskModel() -> VideoCompanionResolver.TaskModel? {
        studioSetupTaskModel(for: .video)
    }
}
