import RxCodeCore
import XCTest
@testable import RxCode

/// Covers the thinking-level vocabulary now that it comes from the provider
/// rather than one hardcoded list.
///
@MainActor
final class ReasoningLevelTests: XCTestCase {

    private var appState: AppState!
    private var window: WindowState!
    private var defaultsSnapshot: [String: Any?] = [:]

    override func setUp() async throws {
        defaultsSnapshot = [
            "selectedAgentProvider": UserDefaults.standard.object(forKey: "selectedAgentProvider"),
        ]
        UserDefaults.standard.set("claudeCode", forKey: "selectedAgentProvider")
        appState = AppState(startBackgroundServices: false)
        appState.selectedAgentProvider = .claudeCode
        appState.agentBackendOverrides[.codex] = MockAgentBackend(provider: .codex)
        appState.agentBackendOverrides[.claudeCode] = MockAgentBackend(provider: .claudeCode)
        window = WindowState()
    }

    override func tearDown() async throws {
        window = nil
        appState = nil
        for (key, value) in defaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Vocabularies

    func testClientReportedLevels() throws {
        let help = "--effort <level>  Effort level\n    (low, future)\n  --other <value>"
        XCTAssertEqual(ClaudeService.reasoningLevels(fromHelp: help).map(\.id), ["low", "future"])
        let json = #"{"models":[{"slug":"model","supported_reasoning_levels":[{"effort":"new","description":"Client description"}]}]}"#
        let catalog = try XCTUnwrap(CodexAppServer.decodeJSONValue(json))
        XCTAssertEqual(CodexAppServer.reasoningLevels(fromCatalog: catalog).first?.1,
                       [ReasoningLevel(id: "new", displayName: "New", levelDescription: "Client description")])
    }

    func testCodexEffortIsValidatedForTheSelectedModel() async {
        appState.codexLevelsByModel = ["first": .levels(["high", "ultra"]), "second": .levels(["high"])]
        let accepted = await appState.sanitizedEffort("ultra", for: .codex, model: "first")
        let rejected = await appState.sanitizedEffort("ultra", for: .codex, model: "second")
        XCTAssertEqual(accepted, "ultra")
        XCTAssertNil(rejected)
    }

    /// ACP has no standard reasoning control, and an empty list is what makes
    /// the picker hide itself rather than render an empty menu.
    func testACPReportsNoLevels() async {
        let acp = await appState.backend(for: .acp).availableReasoningLevels()
        XCTAssertTrue(acp.isEmpty)
    }

    /// The Settings default is picked before any provider is known, so it is
    /// the only place the union belongs — and it must actually be the union.
    func testGlobalDefaultListIsTheUnionWithoutDuplicates() async {
        await appState.loadReasoningLevels(for: .codex)
        await appState.loadReasoningLevels(for: .claudeCode)
        let union = appState.availableEfforts
        XCTAssertEqual(union, ["minimal", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(Set(union).count, union.count, "No duplicates across the two vocabularies")
    }

    // MARK: - Cache

    func testLoadReasoningLevelsPopulatesThenServesFromCache() async {
        XCTAssertTrue(appState.reasoningLevels(for: .codex).isEmpty, "Empty before loading")

        await appState.loadReasoningLevels(for: .codex)

        XCTAssertEqual(appState.reasoningLevels(for: .codex).map(\.id), ["minimal", "low", "medium", "high"])
        XCTAssertTrue(
            appState.reasoningLevels(for: .claudeCode).isEmpty,
            "Loading one provider must not populate another"
        )
    }

    // MARK: - Reconciling a stale selection

    /// Switching Claude → Codex used to leave `max` selected and showing, even
    /// though Codex rejects it.
    func testEffortNotAcceptedByTheNewProviderFallsBackToAuto() async {
        await appState.loadReasoningLevels(for: .codex)
        appState.setSessionEffort("max", in: window)

        appState.reconcileSessionEffort(in: window, provider: .codex)

        XCTAssertNil(window.sessionEffort)
    }

    func testAnEffortTheProviderAcceptsIsKept() async {
        await appState.loadReasoningLevels(for: .codex)
        appState.setSessionEffort("high", in: window)

        appState.reconcileSessionEffort(in: window, provider: .codex)

        XCTAssertEqual(window.sessionEffort, "high")
    }

    /// An unloaded provider reports an empty list, which means "don't know yet"
    /// — not "accepts nothing". Discarding the user's pick on that would lose
    /// it every launch.
    func testSelectionSurvivesWhileLevelsAreStillLoading() {
        appState.setSessionEffort("xhigh", in: window)

        appState.reconcileSessionEffort(in: window, provider: .codex)

        XCTAssertEqual(window.sessionEffort, "xhigh")
    }

    // MARK: - Codex wire format

    func testCodexEffortBecomesAConfigOverride() {
        XCTAssertEqual(
            CodexAppServer.effortOverrides("high"),
            ["-c", "model_reasoning_effort=\"high\""]
        )
    }

    /// "Auto" means "leave whatever ~/.codex/config.toml says".
    func testCodexEmitsNoOverrideForAuto() {
        XCTAssertTrue(CodexAppServer.effortOverrides(nil).isEmpty)
    }

    func testCodexForwardsNewlyReportedLevel() {
        XCTAssertEqual(CodexAppServer.effortOverrides("ultra"), ["-c", "model_reasoning_effort=\"ultra\""])
    }
}
