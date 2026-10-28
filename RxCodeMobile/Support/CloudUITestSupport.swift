#if DEBUG
import Foundation

/// In-process HTTP fixture used only by the cloud UI test launch mode.
/// It exercises the production cloud client and editors with no desktop connection.
final class CloudUITestProtocol: URLProtocol, @unchecked Sendable {
    /// Signed-in fixture account; it owns the board so cards stay editable.
    static let userID = "ui-test-user"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tasks: [[String: Any]] = []
    nonisolated(unsafe) private static var stories: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cloud-ui.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let path = request.url!.path
        var object: Any
        if path == "/api/v1/agent/draft" {
            object = ["title": "Support offline work", "details": "## Acceptance criteria\nBoard data remains available offline."]
        } else if path.hasSuffix("/board-views"), request.httpMethod == "GET" {
            object = ["views": [], "revision": 0]
        } else if path == "/api/v1/devices" {
            object = [["id": "cf8c1089-8a5d-47f9-bcd2-bcfe4c0a1691", "name": "Offline Work Mac"]]
        } else if path == "/api/v1/docs/repositories" {
            if ProcessInfo.processInfo.arguments.contains("-uitest-project-cards") {
                object = ["items": [
                    ["id": "A0000000-0000-0000-0000-000000000001", "name": "Alpha Project"],
                    ["id": "B0000000-0000-0000-0000-000000000002", "name": "Beta Project"]
                ]]
            } else {
                var project = ["id": "project", "name": "Cloud Project"]
                if ProcessInfo.processInfo.arguments.contains("-uitest-feature-navigation") {
                    project["repositoryFullName"] = "rxtech-lab/rxcode"
                }
                object = ["items": [project]]
            }
        } else if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            row["id"] = request.httpMethod == "POST" ? UUID().uuidString : request.url!.lastPathComponent
            if path.contains("/stories") {
                Self.stories.removeAll { $0["id"] as? String == row["id"] as? String }
                Self.stories.append(row)
            } else {
                Self.tasks.removeAll { $0["id"] as? String == row["id"] as? String }
                Self.tasks.append(row)
            }
            object = row
        } else {
            object = [
                "stories": Self.stories, "tasks": Self.tasks,
                "members": [["userId": Self.userID, "name": "UI Test"]],
                "role": "owner", "currentUserId": Self.userID
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
