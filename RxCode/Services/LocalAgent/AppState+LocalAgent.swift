import Foundation
import RxCodeCore

extension AppState {
    /// Downloaded Hugging Face models and the llama.cpp server that runs them.
    var localModels: LocalModelStore { .shared }

    /// RxCode's own agent (RxAgentHarness) on a local model.
    var localAgentBackend: any AgentBackend {
        LocalAgentBackendFactory.backend(permissionServer: permission, store: localModels) { [weak self] in
            self?.videoCompanionTaskModel()
        }
    }

    /// The default task agent (Settings → Tasks), as the video companion
    /// lookup uses it. nil when it is the local agent itself, which can't
    /// answer one-shot prompts.
    func videoCompanionTaskModel() -> VideoCompanionResolver.TaskModel? {
        let agent = defaultTaskAgent()
        guard (agent.provider ?? selectedAgentProvider) != .localAgent else { return nil }
        return VideoCompanionResolver.TaskModel(label: taskAgentLabel(agent)) { [weak self] prompt in
            await self?.runTaskAgentCompletion(prompt: prompt, projectId: nil, model: .agent(agent), verbatim: true)
        }
    }
}
