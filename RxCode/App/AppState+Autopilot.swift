import Foundation
import RxCodeCore

/// High-level autopilot configuration intents: thin pass-throughs to
/// `AutopilotService` for the schema-driven automation settings form and the
/// repo-setup templates. Views call these instead of reaching into `autopilot`.
extension AppState {

    // MARK: - Automation settings

    func automationSchema() async throws -> SchemaEnvelope {
        try await autopilot.getAutomationSchema()
    }

    func automationValues() async throws -> PreferencesValues {
        try await autopilot.getPreferences()
    }

    @discardableResult
    func saveAutomationValues(_ values: JSONValue) async throws -> PreferencesValues {
        try await autopilot.putPreferences(PreferencesValues(values: values))
    }

    // MARK: - Repo setup templates

    func repoSetupSchema() async throws -> SchemaEnvelope {
        try await autopilot.getRepoSetupSchema()
    }

    func repoSetupTemplates() async throws -> [RepoSetupTemplate] {
        try await autopilot.listSetupTemplates().items
    }

    @discardableResult
    func createRepoSetupTemplate(_ input: RepoSetupTemplateInput) async throws -> RepoSetupTemplate {
        try await autopilot.createSetupTemplate(input)
    }

    @discardableResult
    func updateRepoSetupTemplate(id: String, _ input: RepoSetupTemplateInput) async throws -> RepoSetupTemplate {
        try await autopilot.updateSetupTemplate(id: id, input)
    }

    func deleteRepoSetupTemplate(id: String) async throws {
        try await autopilot.deleteSetupTemplate(id: id)
    }
}
