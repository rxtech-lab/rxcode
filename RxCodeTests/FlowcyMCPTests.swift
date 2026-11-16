import RxCodeCore
import RxCodeSync
import XCTest
@testable import RxCode

@MainActor
final class FlowcyMCPTests: XCTestCase {
    func testMobileAllowlistHasNoUnknownOrCredentialOperations() throws {
        let forbidden: Set<String> = ["secretsGetUserKey", "secretsGetBundle", "secretsUpsertFile", "projectSecretsWrite", "docsCreateUploadToken", "releaseInstallToken"]
        for operation in FlowcyTool.operations where operation.route == "mobile" {
            XCTAssertNotNil(AutopilotOp(rawValue: operation.name), operation.name)
            XCTAssertFalse(forbidden.contains(operation.name))
        }
    }

    func testCIProjectionPreservesProgressAndRemovesLogsAndUnrelatedFields() {
        let result = AppState.flowcyCIProjection(.object([
            "runs": .array([.object(["id": .number(1), "status": .string("queued"), "conclusion": .null, "html_url": .string("https://github.com/o/r/actions/runs/1"), "secret": .string("must not leave native service")]),
                            .object(["id": .number(2), "status": .string("in_progress")]),
                            .object(["id": .number(3), "status": .string("completed"), "conclusion": .string("failure")])]),
            "jobs": .array([.object(["id": .number(4), "status": .string("in_progress"), "logs": .string("private")])]),
            "hasMore": .bool(true), "token": .string("private")
        ]))
        guard case .array(let runs)? = result["runs"], case .array(let jobs)? = result["jobs"] else { return XCTFail("Missing collections") }
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first?["status"], .string("queued"))
        XCTAssertEqual(runs.last?["conclusion"], .string("failure"))
        XCTAssertNil(runs.first?["secret"])
        XCTAssertNil(jobs.first?["logs"])
        XCTAssertNil(result["token"])
        XCTAssertEqual(result["hasMore"], .bool(true))
    }

    func testServiceErrorsDoNotExposeRawBodies() throws {
        let app = AppState(startBackgroundServices: false)
        let result = app.safeFlowcyFailure(AutopilotService.ServiceError.apiError(403, "private-token-value"))
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains("permission_denied"))
        XCTAssertFalse(json.contains("private-token-value"))
        XCTAssertEqual(result["isError"], .bool(true))
    }

    func testCatalogAndUnsupportedOperationsDoNotRequireNetwork() async throws {
        let app = AppState(startBackgroundServices: false)
        let result = try await app.ideHandleToolCall(name: FlowcyTool.catalogName, arguments: .object(["operation": .string("docsGetDocument")]), sessionKey: "test")
        guard case .array(let content)? = result["content"], case .string(let text)? = content.first?["text"] else { return XCTFail("Missing catalog text") }
        XCTAssertTrue(text.contains("currentVersion.content"))
        do {
            _ = try await app.ideHandleToolCall(name: FlowcyTool.catalogName, arguments: .object(["operation": .string("secretsGetBundle")]), sessionKey: "test")
            XCTFail("Credential operation must be rejected")
        } catch let error as IDEToolError {
            guard case .notSupported = error else { return XCTFail("Unexpected error") }
        }
    }
}
