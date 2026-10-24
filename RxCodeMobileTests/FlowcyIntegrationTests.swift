import Foundation
import RxCodeCore
import RxCodeSync
import XCTest
@testable import RxCodeMobile

enum FlowcySimulation {
    static var baseURL: String {
        let value = ProcessInfo.processInfo.environment["FLOWCY_SIMULATION_BASE_URL"] ?? ""
        return value.hasPrefix("http://127.0.0.1:") ? value : "http://127.0.0.1:4912/flowcy"
    }
}

final class FlowcyProtocolTests: XCTestCase {
    func testNotificationUsesSubjectInsteadOfIdentifier() {
        let value: JSONValue = .object([
            "id": .string("bbb5fa72-9f1f-41c6-84ac-5380b0e08262"),
            "subject": .string("Hourly task finished"),
            "title": .string("Legacy title")
        ])
        XCTAssertEqual(FlowcyNotificationDetailView.title(value), "Hourly task finished")
        XCTAssertEqual(FlowcyNotificationDetailView.title(.object([
            "subject": .string("  "), "title": .string("Legacy title")
        ])), "Legacy title")
        XCTAssertEqual(FlowcyNotificationDetailView.title(.object([
            "id": .string("bbb5fa72-9f1f-41c6-84ac-5380b0e08262")
        ])), "Notification")
    }

    func testRPCErrorCannotBeReportedAsSuccessfulResult() throws {
        XCTAssertThrowsError(try FlowcyMCPClient.response(#"{"jsonrpc":"2.0","id":"one","error":{"code":-32603}}"#, id: "one"))
        XCTAssertNil(try FlowcyMCPClient.response(#"{"jsonrpc":"2.0","id":"other","result":{}}"#, id: "one"))
    }

    func testNativeToolsUseCanonicalAccountEndpoint() {
        let resource = FlowcyMCPClient.endpoint
        XCTAssertEqual(resource.absoluteString, "https://www.flowcy.dev/api/v1/agent/tools")
        XCTAssertEqual(FlowcyMCPClient.transportURL(resource).absoluteString, "https://www.flowcy.dev/api/v1/agent/tools")
        let unrelated = URL(string: "https://example.com/oauth/token")!
        XCTAssertEqual(FlowcyMCPClient.transportURL(unrelated), unrelated)
    }

    func testUnknownToolsRequireMutationConsent() throws {
        let tool = try JSONDecoder().decode(FlowcyTool.self, from: Data(#"{"name":"future_action","inputSchema":{"type":"object"}}"#.utf8))
        XCTAssertFalse(tool.isReadOnly)
    }
}

/// Requires `postman simulation run postman/simulations/flowcy-mobile.sim.yaml --port 4922`.
final class FlowcyTransportSimulationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1", "Run MobileFlowcyIntegrationTestPlan with the documented Postman simulation.")
    }

    func testDiscoveryAndRealHTTPToolCalls() async throws {
        let client = FlowcyMCPClient(endpoint: URL(string: "\(FlowcySimulation.baseURL)/api/v1/agent/tools")!, session: .shared, token: { _ in "simulation" })
        let tools = try await client.discover()
        XCTAssertEqual(tools.map(\.name), ["list_tasks", "create_task"])
        let result = try await client.call("list_tasks", arguments: .object(["repoId": .string("authorized")]))
        XCTAssertNotNil(result["content"]?.arrayValue)
        let failed = try await client.call("create_task", arguments: .object(["fail": .bool(true)]))
        XCTAssertEqual(failed["isError"]?.boolValue, true)
        do {
            _ = try await client.call("list_tasks", arguments: .object(["repoId": .string("denied")]))
            XCTFail("Denied request must fail")
        } catch FlowcyError.denied { }
        await client.reset()
        do { _ = try await client.call("list_tasks", arguments: .object([:])); XCTFail("Reset must require discovery") }
        catch { }
    }

    @MainActor
    func testFeatureRejectionDoesNotExpireValidAccount() async throws {
        let expired = expectation(forNotification: .rxAuthSessionExpired, object: nil)
        expired.isInverted = true
        var refreshes: [Bool] = []
        let api = FlowcyAPI(baseURL: URL(string: "\(FlowcySimulation.baseURL)")!) { refresh in
            refreshes.append(refresh)
            return "valid-account"
        }
        do { _ = try await api.read("simulation/rejected-feature"); XCTFail("Expected feature error") }
        catch FlowcyError.message { }
        XCTAssertEqual(refreshes, [false, true])
        await fulfillment(of: [expired], timeout: 0.1)
    }

    func testToolDiscoveryRefreshesAccountTokenOnce() async throws {
        let client = FlowcyMCPClient(endpoint: URL(string: "\(FlowcySimulation.baseURL)/api/v1/agent/tools")!,
                                    session: .shared, token: { refresh in refresh ? "simulation" : "expired" })
        let tools = try await client.discover()
        XCTAssertEqual(tools.count, 2)
    }

    @MainActor
    func testStreamingOverHTTPAndRefresh() async throws {
        var calls: [Bool] = []
        let api = FlowcyAPI(baseURL: URL(string: "\(FlowcySimulation.baseURL)")!) { refresh in calls.append(refresh); return "simulation" }
        let (bytes, _) = try await api.request(path: "agent/chat", body: .object(["messages": .array([])]))
        var events: [JSONValue] = []
        for try await line in bytes.lines {
            events.append(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))
        }
        XCTAssertEqual(events.first?["text"]?.stringValue, "**Actual simulated transport** ✓")
        XCTAssertEqual(events.last?["type"]?.stringValue, "finish")
        XCTAssertEqual(calls, [false])
    }
}

@MainActor
final class FlowcyAgentSimulationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1", "Run MobileFlowcyIntegrationTestPlan with the documented Postman simulation.")
    }

    private func connectedTools() async throws -> FlowcyToolsState {
        let client = FlowcyMCPClient(endpoint: URL(string: "\(FlowcySimulation.baseURL)/api/v1/agent/tools")!, session: .shared, token: { _ in "simulation" })
        let tools = FlowcyToolsState(client: client)
        await tools.connect()
        XCTAssertTrue(tools.isConnected)
        return tools
    }

    private func agent() -> FlowcyAgentState {
        let agent = FlowcyAgentState(api: FlowcyAPI(baseURL: URL(string: "\(FlowcySimulation.baseURL)")!, token: { _ in "simulation" }))
        agent.restore(accountID: "flowcy-simulation-" + UUID().uuidString)
        return agent
    }

    func testPromptCallsDiscoveredToolAndRendersActualResult() async throws {
        let tools = FlowcyToolsState(client: FlowcyMCPClient(endpoint: URL(string: "\(FlowcySimulation.baseURL)/api/v1/agent/tools")!, session: .shared, token: { _ in "simulation" }))
        XCTAssertFalse(tools.isConnected)
        let agent = agent()
        agent.send("Tool list my tasks", tools: tools, cloud: MobileCloudState())
        try await wait { !agent.isStreaming }
        XCTAssertNil(agent.error)
        XCTAssertTrue(agent.messages.contains { $0.role == "tool" && $0.text.contains("authorized") })
        XCTAssertTrue(agent.messages.last?.text.contains("simulated transport") == true)
        agent.newChat()
        XCTAssertTrue(agent.messages.isEmpty)
    }

    func testMutationWaitsForNativeConsentAndDenialIsReturnedToModel() async throws {
        let tools = try await connectedTools()
        let agent = agent()
        agent.send("Tool Create a task", tools: tools, cloud: MobileCloudState())
        try await wait { agent.pendingTool != nil }
        XCTAssertEqual(agent.pendingTool?.tool.name, "create_task")
        XCTAssertFalse(agent.messages.contains { $0.role == "tool" })
        agent.approve(false)
        try await wait { !agent.isStreaming }
        XCTAssertTrue(agent.messages.contains { $0.role == "tool" && $0.text.contains("denied") })
        agent.newChat()
    }

    func testCancellationStopsStreamingAndAccountSwitchClearsConversation() async throws {
        let tools = try await connectedTools()
        let agent = agent()
        agent.send("Slow reply", tools: tools, cloud: MobileCloudState())
        try await wait { agent.messages.contains { $0.role == "assistant" && !$0.text.isEmpty } }
        agent.cancel()
        XCTAssertFalse(agent.isStreaming)
        agent.restore(accountID: nil)
        XCTAssertTrue(agent.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(agent.messages.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), "Timed out waiting for agent state")
    }
}

@MainActor
final class FlowcyTaskLoadingSimulationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1"
                          && ProcessInfo.processInfo.arguments.contains("-uitest-cloud"),
                          "Run MobileFlowcyIntegrationTestPlan with the Postman simulation.")
    }

    private func cloud(token: @escaping (Bool) async -> String?) -> MobileCloudState {
        MobileCloudState(service: ProjectCloudService(session: .shared,
            baseURL: URL(string: FlowcySimulation.baseURL)!, tokenProvider: token))
    }

    func testInitialDiscoveryKeepsReloadKeyStableAndLoadsBoards() async throws {
        let cloud = cloud { _ in "simulation" }
        cloud.error = "Error from an earlier refresh"
        let state = MobileAppState()
        state.taskCloud = cloud
        state.usesCloudTasks = true
        let key = state.taskSyncReloadKey

        let error = await state.loadAllTaskBoards()

        XCTAssertNil(error)
        XCTAssertNil(cloud.error)
        XCTAssertEqual(state.taskSyncReloadKey, key, "Discovering projects must not restart the initial load")
        XCTAssertEqual(state.taskProjects.count, 1)
        XCTAssertEqual(state.taskSnapshots.values.first?.board.tasks.first?.title, "Loaded task")
        XCTAssertTrue(state.loadingTaskBoardProjects.isEmpty)
    }

    func testCancelledRefreshCannotPoisonSuccessfulRefresh() async throws {
        let started = expectation(description: "First project request")
        var requests = 0
        let cloud = cloud { _ in
            requests += 1
            if requests == 1 { started.fulfill(); return "slow-projects" }
            return "simulation"
        }
        let first = Task { await cloud.refresh() }
        await fulfillment(of: [started], timeout: 3)
        // Allow the request to reach the delayed HTTP fixture before canceling.
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        try await cloud.refreshProjects()
        await first.value

        XCTAssertNil(cloud.error)
        XCTAssertNil(cloud.deviceError)
        XCTAssertEqual(cloud.projects.count, 1)
    }

    func testCancelledBoardLoadIsNotAUserFacingFailure() async throws {
        let started = expectation(description: "Board request")
        var requests = 0
        let cloud = cloud { _ in
            requests += 1
            if requests == 2 { started.fulfill() }
            return "slow-board"
        }
        let state = MobileAppState()
        state.taskCloud = cloud
        state.usesCloudTasks = true
        let load = Task { await state.loadAllTaskBoards() }
        await fulfillment(of: [started], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        load.cancel()
        let error = await load.value

        XCTAssertNil(error)
        XCTAssertNil(cloud.error)
        XCTAssertTrue(state.loadingTaskBoardProjects.isEmpty)
        let retryError = await state.loadAllTaskBoards()
        XCTAssertNil(retryError)
        XCTAssertEqual(state.taskSnapshots.count, 1)
    }

    func testActualProjectFailureIsReportedAndNextLoadRecovers() async throws {
        var failing = true
        let cloud = cloud { _ in failing ? "project-error" : "simulation" }
        let state = MobileAppState()
        state.taskCloud = cloud
        state.usesCloudTasks = true
        let error = await state.loadAllTaskBoards()
        XCTAssertNotNil(error)
        XCTAssertTrue(state.taskProjects.isEmpty)

        failing = false
        let retryError = await state.loadAllTaskBoards()
        XCTAssertNil(retryError)
        XCTAssertEqual(state.taskSnapshots.count, 1)
    }
}
