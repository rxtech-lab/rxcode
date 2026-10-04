import RxCodeCore
import XCTest
@testable import RxCode

/// Covers the thinking-level vocabulary now that it comes from the provider
/// rather than one hardcoded list.
///
/// The bug this replaces: the composer offered `low/medium/high/xhigh/max` for
/// every agent. Those are Claude's. Codex accepts `minimal/low/medium/high` and
/// rejects the other two, so the menu was showing a Codex user two levels that
/// could not work and hiding one that could.
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

    func testClaudeAndCodexDoNotShareALevelSet() {
        let claude = [ReasoningLevel].claudeCodeEfforts.map(\.id)
        let codex = [ReasoningLevel].codexEfforts.map(\.id)

        XCTAssertEqual(claude, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(codex, ["minimal", "low", "medium", "high"])
        XCTAssertFalse(codex.contains("xhigh"), "xhigh is Claude's; codex rejects it")
        XCTAssertFalse(codex.contains("max"), "max is Claude's; codex rejects it")
        XCTAssertFalse(claude.contains("minimal"), "minimal is Codex's")
    }

    func testBackendsReportTheirOwnLevels() async {
        let claude = await appState.backend(for: .claudeCode).availableReasoningLevels()
        let codex = await appState.backend(for: .codex).availableReasoningLevels()

        XCTAssertEqual(claude.map(\.id), [ReasoningLevel].claudeCodeEfforts.map(\.id))
        XCTAssertEqual(codex.map(\.id), [ReasoningLevel].codexEfforts.map(\.id))
    }

    /// ACP has no standard reasoning control, and an empty list is what makes
    /// the picker hide itself rather than render an empty menu.
    func testACPReportsNoLevels() async {
        let acp = await appState.backend(for: .acp).availableReasoningLevels()
        XCTAssertTrue(acp.isEmpty)
    }

    /// The Settings default is picked before any provider is known, so it is
    /// the only place the union belongs — and it must actually be the union.
    func testGlobalDefaultListIsTheUnionWithoutDuplicates() {
        let union = AppState.availableEfforts
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

    /// codex rejects the whole config on a bad enum value, so a stale Claude
    /// level must be dropped rather than forwarded — otherwise the turn fails
    /// outright instead of just ignoring the setting.
    func testCodexDropsALevelItDoesNotAccept() {
        XCTAssertTrue(CodexAppServer.effortOverrides("max").isEmpty)
        XCTAssertTrue(CodexAppServer.effortOverrides("xhigh").isEmpty)
    }
}
