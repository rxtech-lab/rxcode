import Foundation
import RxCodeCore
import XCTest
@testable import RxCodeMobile

@MainActor
final class FlowcyPushLifecycleTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "FlowcyPushTests." + UUID().uuidString)! }
    private let token = String(repeating: "a", count: 64)

    func testTokenBeforeSignInWaitsAndRotationUpdatesSameDevice() async throws {
        var calls: [(String, JSONValue)] = []
        let push = FlowcyPushRegistration(defaults: defaults(), deviceName: "Test iPhone") { calls.append(($0, $1)) }
        await push.updateToken(token, environment: "sandbox", accountID: nil)
        XCTAssertTrue(calls.isEmpty)
        await push.synchronize(accountID: "owner")
        XCTAssertTrue(push.isRegistered)
        await push.synchronize(accountID: "owner")
        XCTAssertEqual(calls.count, 1)
        await push.updateToken(String(repeating: "b", count: 64), environment: "sandbox", accountID: "owner")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].1["id"], calls[1].1["id"])
        XCTAssertEqual(calls[1].1["provider"], .string("apns"))
        try await push.disconnect(accountID: "owner")
        XCTAssertEqual(calls.last?.0, "DELETE")
        XCTAssertFalse(push.isRegistered)
    }

    func testDisconnectWaitsForInFlightRegistrationAndPreventsLatePut() async throws {
        var events: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        let push = FlowcyPushRegistration(defaults: defaults(), deviceName: "Test iPhone") { method, _ in
            events.append(method)
            if method == "PUT" { await withCheckedContinuation { finish = $0 } }
        }
        let registering = Task { await push.updateToken(token, environment: "production", accountID: "owner") }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish)
        let disconnecting = Task { try await push.disconnect(accountID: "owner", disable: true) }
        await Task.yield()
        await push.synchronize(accountID: "owner")
        finish?.resume()
        await registering.value
        try await disconnecting.value
        XCTAssertEqual(events, ["PUT", "DELETE"])
        await push.synchronize(accountID: "owner")
        XCTAssertEqual(events, ["PUT", "DELETE"])
        XCTAssertFalse(push.isEnabled)
    }

    func testFailedRemovalCanBeRetriedAndNeverClaimsDisconnected() async throws {
        var shouldFail = true
        let push = FlowcyPushRegistration(defaults: defaults(), deviceName: "Test iPhone") { method, _ in
            if method == "DELETE", shouldFail { throw URLError(.notConnectedToInternet) }
        }
        await push.updateToken(token, environment: "sandbox", accountID: "owner")
        do { try await push.disconnect(accountID: "owner"); XCTFail("Expected failed removal") } catch { }
        XCTAssertTrue(push.isRegistered)
        XCTAssertNotNil(push.error)
        shouldFail = false
        try await push.disconnect(accountID: "owner")
        XCTAssertFalse(push.isRegistered)
        XCTAssertNil(push.error)
    }

    func testAccountSwitchCannotOverwriteAnUnremovedRegistration() async throws {
        var puts = 0
        let push = FlowcyPushRegistration(defaults: defaults(), deviceName: "Test iPhone") { method, _ in
            if method == "PUT" { puts += 1 }
        }
        await push.updateToken(token, environment: "sandbox", accountID: "first")
        push.sessionEnded()
        await push.synchronize(accountID: "second")
        XCTAssertEqual(puts, 1)
        XCTAssertFalse(push.isRegistered)
        XCTAssertNotNil(push.error)
        try await push.disconnect(accountID: "first")
        await push.synchronize(accountID: "second")
        XCTAssertEqual(puts, 2)
        XCTAssertTrue(push.isRegistered)
    }

    func testRegistrationFailureAndSessionEndDoNotClaimSuccess() async {
        let push = FlowcyPushRegistration(defaults: defaults(), deviceName: "Test iPhone") { _, _ in throw URLError(.notConnectedToInternet) }
        await push.updateToken(token, environment: "sandbox", accountID: "owner")
        XCTAssertFalse(push.isRegistered)
        XCTAssertNotNil(push.error)
        push.sessionEnded()
        XCTAssertFalse(push.isRegistered)
    }
}

final class FlowcyPushRoutingTests: XCTestCase {
    func testPlainBackendPushOpensInboxInsteadOfRemoteThread() throws {
        let route = try XCTUnwrap(FlowcyPushDestination(userInfo: ["source": "flowcy", "sessionId": "untrusted-remote-thread"]))
        XCTAssertNil(route.projectID)
        XCTAssertNil(FlowcyPushDestination(userInfo: ["sessionId": "real-remote-thread"]))
    }
    func testProjectTaskScopeIsParsedWithoutOpeningArbitraryURLs() throws {
        let route = try XCTUnwrap(FlowcyPushDestination(userInfo: ["source": "flowcy", "projectId": "project", "taskId": "task", "url": "https://untrusted.test"]))
        XCTAssertEqual(route.projectID, "project")
        XCTAssertEqual(route.taskID, "task")
        XCTAssertNil(FlowcyPushDestination(userInfo: ["source": "flowcy", "projectId": "\n", "taskId": "task"])?.taskID)
    }
}

@MainActor
final class FlowcyPushTransportSimulationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1", "Run MobileFlowcyIntegrationTestPlan against the Postman simulation.")
    }
    func testAccountRegistrationAndRemovalUseRealHTTP() async throws {
        let api = FlowcyAPI(baseURL: URL(string: "\(FlowcySimulation.baseURL)")!, notifySessionExpiry: false, token: { _ in "simulation" })
        let push = FlowcyPushRegistration(defaults: UserDefaults(suiteName: "PushHTTP." + UUID().uuidString)!, deviceName: "Simulation iPhone") { method, body in
            _ = try await api.read("notifications/devices", method: method, body: body)
        }
        await push.updateToken(String(repeating: "a", count: 64), environment: "sandbox", accountID: "owner")
        XCTAssertTrue(push.isRegistered)
        let devices = try await api.read("notifications/devices")
        XCTAssertEqual(devices.arrayValue?.first?["id"]?.stringValue, push.deviceID)
        XCTAssertNil(devices.arrayValue?.first?["token"])
        try await push.disconnect(accountID: "owner")
        let removed = try await api.read("notifications/devices")
        XCTAssertEqual(removed.arrayValue?.count, 0)
    }
}
