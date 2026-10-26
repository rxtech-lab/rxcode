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
    func testComputerUseRequiresExplicitGrantEvenInAutoMode() async {
        let server = PermissionServer()
        await server.registerSession(sid: "cua-session", projectKey: "cua-test", mode: .auto)
        let (_, stream) = await server.subscribe()
        let first = Task {
            await server.requestDecision(toolUseId: "cua-first", sessionId: "cua-session",
                                         toolName: "mcp__cua_repl__js", toolInput: [:], mode: .auto)
        }
        let requests = await awaitRequests(stream, count: 1)
        XCTAssertEqual(requests.first?.id, "cua-first")
        await server.respond(toolUseId: "cua-first", decision: .deny)
        let denied = await first.value
        XCTAssertEqual(denied, .deny)

        let retry = Task {
            await server.requestDecision(toolUseId: "cua-retry", sessionId: "cua-session",
                                         toolName: "mcp__cua_repl__js", toolInput: [:], mode: .auto)
        }
        _ = await awaitRequests(stream, count: 1)
        await server.respond(toolUseId: "cua-retry", decision: .allowSessionTool)
        let allowed = await retry.value
        XCTAssertEqual(allowed, .allow)
        let later = await server.requestDecision(toolUseId: "cua-later", sessionId: "cua-session",
                                                toolName: "mcp__cua__click", toolInput: [:], mode: .auto)
        XCTAssertEqual(later, .allow)

        let other = Task {
            await server.requestDecision(toolUseId: "cua-other", sessionId: "another-session",
                                         toolName: "mcp__cua__click", toolInput: [:], mode: .auto)
        }
        _ = await awaitRequests(stream, count: 1)
        await server.respond(toolUseId: "cua-other", decision: .deny)
        let otherDecision = await other.value
        XCTAssertEqual(otherDecision, .deny)
        await server.stop()
    }

}
