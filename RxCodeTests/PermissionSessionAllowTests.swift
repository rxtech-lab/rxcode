import XCTest
import RxCodeCore
@testable import RxCode

/// Regression: after "Allow this tool for the session" the user must not be prompted
/// again — neither for calls already queued nor for later calls on non-Claude transports.
final class PermissionSessionAllowTests: XCTestCase {

    /// Waits until the server has broadcast `count` requests (i.e. they are pending).
    private func awaitRequests(_ stream: AsyncStream<PermissionRequest>, count: Int) async -> [PermissionRequest] {
        var received: [PermissionRequest] = []
        for await request in stream {
            received.append(request)
            if received.count == count { break }
        }
        return received
    }

    func testSessionToolAllowResolvesQueuedSiblingRequests() async {
        let server = PermissionServer()
        let (_, stream) = await server.subscribe()

        let first = Task { await server.requestDecision(toolUseId: "a", sessionId: "s1", toolName: "Edit", toolInput: [:], mode: .default) }
        let second = Task { await server.requestDecision(toolUseId: "b", sessionId: "s1", toolName: "Edit", toolInput: [:], mode: .default) }
        let otherSession = Task { await server.requestDecision(toolUseId: "c", sessionId: "s2", toolName: "Edit", toolInput: [:], mode: .default) }
        _ = await awaitRequests(stream, count: 3)

        let autoResolved = await server.respond(toolUseId: "a", decision: .allowSessionTool)

        XCTAssertEqual(autoResolved, ["b"])
        let firstDecision = await first.value
        let secondDecision = await second.value
        XCTAssertEqual(firstDecision, .allow)
        XCTAssertEqual(secondDecision, .allow)

        // A different session keeps its own prompt.
        await server.respond(toolUseId: "c", decision: .deny)
        let otherDecision = await otherSession.value
        XCTAssertEqual(otherDecision, .deny)
    }

    func testSessionToolAllowSkipsPromptForLaterRequests() async {
        let server = PermissionServer()
        let (_, stream) = await server.subscribe()

        let first = Task { await server.requestDecision(toolUseId: "a", sessionId: "s1", toolName: "Bash", toolInput: [:], mode: .default) }
        _ = await awaitRequests(stream, count: 1)
        await server.respond(toolUseId: "a", decision: .allowSessionTool)
        _ = await first.value

        let later = await server.requestDecision(toolUseId: "b", sessionId: "s1", toolName: "Bash", toolInput: [:], mode: .default)
        XCTAssertEqual(later, .allow)
    }
}
