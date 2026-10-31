import Foundation
import RxCodeCore

extension AppState {
    /// Downloaded Hugging Face models and the llama.cpp server that runs them.
    var localModels: LocalModelStore { .shared }

    /// RxCode's own agent (RxAgentHarness) on a local model.
    var localAgentBackend: any AgentBackend {
        LocalAgentBackendFactory.backend(permissionServer: permission, store: localModels)
    }
}
