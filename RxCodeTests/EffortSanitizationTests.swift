import RxCodeCore
import XCTest
@testable import RxCode

/// Covers the guard that stops a thinking level reaching an agent that rejects
/// it.
///
/// Effort is chosen in places that don't know which agent will run: the global
/// Settings default spans every provider, and a session carries its pick across
/// a provider switch. So a value can be perfectly valid where it was chosen and
/// invalid by the time it is sent — Claude launching with `--effort minimal`,
/// or codex failing its whole config on `max`.
///
/// Every send path funnels through `resolveStreamPreflight`, so these assert on
/// what actually reached the backend rather than on the helper alone.
@MainActor
final class EffortSanitizationTests: XCTestCase {

    private var appState: AppState!
    private var claudeBackend: MockAgentBackend!
    private var codexBackend: MockAgentBackend!
    private var window: WindowState!
    private var project: Project!
    private var defaultsSnapshot: [String: Any?] = [:]

    override func setUp() async throws {
        defaultsSnapshot = [
            "selectedAgentProvider": UserDefaults.standard.object(forKey: "selectedAgentProvider"),
            "selectedEffort": UserDefaults.standard.object(forKey: "selectedEffort"),
        ]
        UserDefaults.standard.set("claudeCode", forKey: "selectedAgentProvider")

        appState = AppState(startBackgroundServices: false)
        appState.selectedAgentProvider = .claudeCode

        claudeBackend = MockAgentBackend(provider: .claudeCode)
        codexBackend = MockAgentBackend(provider: .codex)
        appState.agentBackendOverrides[.claudeCode] = claudeBackend
        appState.agentBackendOverrides[.codex] = codexBackend

        project = Project(
            name: "effort",
            path: "/tmp/rxcode-effort-\(UUID().uuidString)",
            gitHubRepo: nil
        )
        appState.projects = [project]

        window = WindowState()
        window.selectedProject = project
    }

    override func tearDown() async throws {
        for key in appState.sessionStates.keys where appState.sessionStates[key]?.isStreaming == true {
            appState.sessionStates[key]?.streamTask?.cancel()
            appState.sessionStates[key]?.flushTask?.cancel()
        }
        window = nil
        claudeBackend = nil
        codexBackend = nil
        appState = nil
        for (key, value) in defaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Runs one turn and returns the effort the backend was actually asked for.
    private func effortReachingBackend(
        _ backend: MockAgentBackend,
        provider: AgentProvider,
        effort: String?
    ) async throws -> String?? {
        _ = try await appState.sendCrossProject(
            projectId: project.id,
            threadId: nil,
            prompt: "go",
            agentProvider: provider,
            effort: effort,
            waitForResponse: true,
            timeoutSeconds: 10
        )
        let requests = await backend.receivedRequests
        return requests.last.map(\.effort)
    }

    // MARK: - The union default leaking across providers

    /// `minimal` is Codex's. Settings offers it because the global default is
    /// chosen before a provider is known, but Claude would take it straight to
    /// `--effort minimal`.
    func testCodexOnlyLevelIsDroppedBeforeReachingClaude() async throws {
        let sent = try await effortReachingBackend(claudeBackend, provider: .claudeCode, effort: "minimal")
        XCTAssertEqual(sent, .some(nil), "Claude must be launched with no --effort rather than `minimal`")
    }

    /// The mirror case: `xhigh` is Claude's, and codex rejects its whole config
    /// on a bad enum — so this would fail the turn outright, not just be
    /// ignored. The sanitization is central, so the SDK-backed Codex client is
    /// handed the same already-cleaned value.
    func testClaudeOnlyLevelIsDroppedBeforeReachingCodex() async throws {
        let sent = try await effortReachingBackend(codexBackend, provider: .codex, effort: "xhigh")
        XCTAssertEqual(sent, .some(nil))
    }

    func testALevelTheProviderAcceptsIsForwardedUnchanged() async throws {
        let claude = try await effortReachingBackend(claudeBackend, provider: .claudeCode, effort: "xhigh")
        XCTAssertEqual(claude, .some("xhigh"))

        let codex = try await effortReachingBackend(codexBackend, provider: .codex, effort: "minimal")
        XCTAssertEqual(codex, .some("minimal"))
    }

    /// A session that picked `minimal` under Codex and was switched to Claude
    /// before the toolbar's reconciliation ran.
    func testEffortCarriedAcrossAProviderSwitchIsDropped() async throws {
        appState.setSessionEffort("minimal", in: window)
        XCTAssertEqual(window.sessionEffort, "minimal", "Valid while the session was on Codex")

        let sent = try await effortReachingBackend(
            claudeBackend,
            provider: .claudeCode,
            effort: window.sessionEffort
        )

        XCTAssertEqual(sent, .some(nil), "Claude must not be launched with --effort minimal")
    }

    /// ACP has no reasoning control at all, so there is no level to forward.
    func testNoLevelSurvivesForAProviderWithNoReasoningControl() async {
        let sanitized = await appState.sanitizedEffort("high", for: .acp)
        XCTAssertNil(sanitized)
    }

    // MARK: - The helper directly

    func testSanitizerLoadsLevelsItselfRatherThanTrustingAColdCache() async {
        XCTAssertTrue(
            appState.reasoningLevels(for: .codex).isEmpty,
            "Nothing has warmed the cache yet"
        )

        let sanitized = await appState.sanitizedEffort("minimal", for: .codex)

        XCTAssertEqual(sanitized, "minimal", "A cold cache must not reject a valid level")
    }

    func testNilEffortStaysNil() async {
        let sanitized = await appState.sanitizedEffort(nil, for: .claudeCode)
        XCTAssertNil(sanitized)
    }

    // MARK: - `/effort` before any picker has loaded levels

    /// `handleNativeSlashCommand` can run before the composer or the ⌘ sheet has
    /// warmed the cache. An unloaded provider reports no levels, which would
    /// reject every level — including valid ones — and silently reset to Auto.
    func testEffortSlashCommandKeepsAValidLevelOnAColdCache() async {
        XCTAssertTrue(appState.reasoningLevels(for: .claudeCode).isEmpty)

        let handled = await appState.handleNativeSlashCommand("/effort high", in: window)

        XCTAssertTrue(handled)
        XCTAssertEqual(window.sessionEffort, "high")
    }

    func testEffortSlashCommandStillRejectsALevelTheProviderLacks() async {
        window.sessionModel = nil
        appState.selectedAgentProvider = .codex

        let handled = await appState.handleNativeSlashCommand("/effort max", in: window)

        XCTAssertTrue(handled)
        XCTAssertNil(window.sessionEffort, "`max` is Claude's; a Codex thread resets to Auto")
    }
}
