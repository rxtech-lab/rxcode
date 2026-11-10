import Foundation
import XCTest
import RxCodeCore
import CryptoKit
import RxCodeSync
@testable import RxCodeMobile

private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class ProjectCloudServiceTests: XCTestCase {
    private func service(token: @escaping (Bool) async -> String? = { _ in "token" }) -> ProjectCloudService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudURLProtocol.self]
        return ProjectCloudService(session: URLSession(configuration: config), baseURL: URL(string: "https://cloud.test")!, tokenProvider: token)
    }

    func testEncryptedActivityHTTPRoundTrip() async throws {
        guard let base = ProcessInfo.processInfo.environment["RXCODE_TASK_ACTIVITY_SIMULATION"],
              let baseURL = URL(string: base) else { throw XCTSkip("Requires the local Postman task activity simulation") }
        let api = ProjectCloudService(session: .shared, baseURL: baseURL) { _ in "simulation-token" }
        let desktop = DeviceIdentity(privateKey: .init()), phone = DeviceIdentity(privateKey: .init())
        let activity = CloudTaskActivity(projectID: "project", taskID: "task", updatedAt: Date(),
            sourceProjectID: UUID(), sourceTaskID: UUID(), senderPublicKey: desktop.publicKeyHex, sessionID: "chat",
            runs: [TaskRunTurn(id: 0, prompt: "Secret follow-up", response: "Secret response", didError: false)],
            connections: [], attentionReason: "Secret feedback")
        let envelope = try EncryptedTaskActivity.seal(activity, identity: desktop, recipientKeys: [phone.publicKeyHex])
        try await api.saveTaskActivity(projectId: "project", taskId: "task", envelope: envelope)
        let records = try await api.taskActivity(projectId: "project", recipient: phone.publicKeyHex)
        let record = try XCTUnwrap(records.first { $0.envelope.sender == desktop.publicKeyHex })
        XCTAssertEqual(try record.envelope.open(identity: phone, trustedSenders: [desktop.publicKeyHex],
            projectID: "project", taskID: record.taskId), activity)
        do {
            _ = try await api.taskActivity(projectId: "failure", recipient: phone.publicKeyHex)
            XCTFail("Expected storage error")
        } catch AutopilotService.ServiceError.apiError(let status, _) { XCTAssertEqual(status, 503) }
    }

    func testCloudReadDoesNotRequirePairedDesktopAndRefreshesUnauthorizedToken() async throws {
        var calls = [Bool]()
        let api = service { force in calls.append(force); return force ? "fresh" : "old" }
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/docs/repositories/project/tasks")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, "{}") }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return (200, #"{"stories":[],"tasks":[{"id":"task","title":"Offline Mac","assignedDeviceId":"laptop"}]}"#)
        }
        let board = try await api.board(projectId: "project")
        XCTAssertEqual(board.tasks.first?.fields.assignedDeviceId, "laptop")
        XCTAssertEqual(calls, [false, true])
    }

    func testProjectPagination() async throws {
        CloudURLProtocol.handler = { request in
            if request.url!.query!.contains("cursor=next") {
                return (200, #"{"items":[{"id":"two","name":"Two"}],"pagination":{"hasMore":false}}"#)
            }
            return (200, #"{"items":[{"id":"one","name":"One"}],"pagination":{"hasMore":true,"nextCursor":"next"}}"#)
        }
        let projects = try await service().listProjects()
        XCTAssertEqual(projects.map(\.id), ["one", "two"])
    }

    func testRepeated401FailsWithoutInfiniteRetry() async throws {
        var tokens = 0
        let api = service { _ in tokens += 1; return "rejected" }
        CloudURLProtocol.handler = { _ in (401, "{}") }
        do { _ = try await api.listDevices(); XCTFail("Expected sign-in error") }
        catch AutopilotService.ServiceError.notAuthenticated { }
        XCTAssertEqual(tokens, 2)
    }

    func testAssignmentPatchAndServerError() async throws {
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            // URLSession may represent the body as a stream when URLProtocol receives it.
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? data) as! [String: Any]
            XCTAssertTrue(body["assignedDeviceId"] is NSNull)
            return (403, #"{"error":"Project access denied"}"#)
        }
        do {
            _ = try await service().updateTask(projectId: "project", taskId: "task", fields: CloudTaskFields(title: "Clear assignment"))
            XCTFail("Expected permission error")
        } catch AutopilotService.ServiceError.apiError(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Project access denied")
        }
    }
}
