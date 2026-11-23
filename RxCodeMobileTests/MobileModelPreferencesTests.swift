import Foundation
import RxCodeCore
import RxCodeSync
import XCTest
@testable import RxCodeMobile

@MainActor
final class MobileModelPreferencesTests: XCTestCase {
    func testRestoresProviderQualifiedChoiceAndRejectsStaleCapabilities() throws {
        let suite = "MobileModelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = AgentModel(provider: .codex, id: "shared", displayName: "Codex model")
        let acp = AgentModel(provider: .acp, id: "shared", displayName: "ACP model")

        MobileModelPreferences.remember(provider: codex.provider, model: codex.id, effort: "high", defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = snapshot(models: [acp, codex], levels: [codex.key: .levels(["high"])])
        XCTAssertEqual(MobileModelPreferences.selection(in: settings, defaults: reopened),
                       TaskAgentConfig(provider: .codex, model: "shared", effort: "high"))
        let changed = snapshot(models: [codex], levels: [codex.key: .levels(["low"])])
        XCTAssertEqual(MobileModelPreferences.selection(in: changed, defaults: reopened),
                       TaskAgentConfig(provider: .codex, model: "shared"))
        XCTAssertNil(MobileModelPreferences.selection(in: snapshot(models: [acp], levels: nil), defaults: reopened))

        MobileModelPreferences.remember(provider: codex.provider, model: codex.id, effort: nil, defaults: reopened)
        XCTAssertNil(MobileModelPreferences.selection(in: settings, defaults: reopened)?.effort)
        MobileModelPreferences.remember(provider: nil, model: nil, effort: nil, defaults: reopened)
        XCTAssertNil(MobileModelPreferences.selection(in: settings, defaults: reopened))
    }

    private func snapshot(models: [AgentModel], levels: [String: [ReasoningLevel]]?) -> MobileSettingsSnapshot {
        MobileSettingsSnapshot(
            selectedAgentProvider: .codex, selectedModel: "shared", selectedACPClientId: "", selectedEffort: "auto",
            permissionMode: .default, summarizationProvider: "", summarizationProviderDisplayName: "",
            openAISummarizationEndpoint: "", openAISummarizationModel: "", notificationsEnabled: true,
            focusMode: false, autoArchiveEnabled: false, archiveRetentionDays: 7,
            autoPreviewSettings: .init(), availableEfforts: [], reasoningLevelsByModel: levels, availableModels: models
        )
    }
}
