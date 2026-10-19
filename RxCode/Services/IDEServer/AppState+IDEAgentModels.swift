import Foundation
import RxCodeCore

extension AppState {
    @MainActor
    func handleListAgentModels() -> JSONValue {
        let sections = availableAgentModelSections()
        let providers: [JSONValue] = AgentProvider.allCases.map { provider in
            let groups: [JSONValue] = sections.filter { $0.provider == provider }.map { section in
                let client = provider == .acp ? acpClients.first { "acp:\($0.id)" == section.id } : nil
                let source: String
                switch provider {
                case .claudeCode: source = "built_in"
                case .codex: source = codexModels.isEmpty ? "fallback" : "discovered"
                case .acp:
                    source = client?.models.isEmpty == true && (client?.modelOptions?.isEmpty ?? true)
                        ? "client_default" : "configured"
                }
                return .object([
                    "id": .string(section.id),
                    "name": .string(section.title),
                    "client_id": client.map { .string($0.id) } ?? .null,
                    "model_source": .string(source),
                    "models": .array(section.models.map { model in
                        .object([
                            "id": .string(model.id),
                            "name": .string(model.displayName),
                            "description": .string(model.description),
                        ])
                    }),
                ])
            }
            return .object([
                "provider": .string(provider.rawValue),
                "name": .string(provider.displayNameText),
                "groups": .array(groups),
            ])
        }
        return jsonTextResult(.object(["providers": .array(providers)]))
    }
}
