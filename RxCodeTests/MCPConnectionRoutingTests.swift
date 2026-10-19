import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class MCPConnectionRoutingTests: XCTestCase {
    private var root: URL!
    private var service: MCPService!
    private let project = "/tmp/mcp-routing-project"
    private let bridge = (command: "/usr/bin/true", args: ["bridge"])

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(MCPConfiguration()).write(to: root.appendingPathComponent("mcp.json"))
        service = MCPService(
            baseURL: root,
            claudeService: ClaudeService(cliStore: CLISessionStore(metaStore: SessionMetaStore()))
        )
        try await service.add(spec: spec("broken"), scope: .user, projectPath: nil)
        try await service.add(spec: spec("healthy"), scope: .user, projectPath: nil)
    }

    override func tearDown() async throws {
        service = nil
        try FileManager.default.removeItem(at: root)
    }

    func testFailedProbeIsExcludedFromEveryProviderAndSDK() async throws {
        // A nonexistent executable fails without depending on network access.
        let result = await service.probe(name: "broken", projectPath: project)
        XCTAssertFalse(result.ok)
        try await assertRoutedNames(["healthy"])
        // Health follows the connection across projects, while it remains listed
        // and enabled in Settings for diagnostics and recovery.
        let records = await service.enabledServerRecords(projectPath: "/tmp/another-project")
        XCTAssertEqual(records.map(\.name), ["healthy"])
        let settings = try await service.list(projectPath: project)
        XCTAssertEqual(settings.count, 2)
        XCTAssertTrue(settings.allSatisfy(\.effectiveEnabled))
    }

    func testSuccessfulRetestRestoresRouting() async throws {
        let detail = try await service.get(name: "broken", projectPath: project)
        await service.recordProbeResult(MCPProbeResult(ok: false), for: detail)
        try await assertRoutedNames(["healthy"])
        await service.recordProbeResult(MCPProbeResult(ok: true), for: detail)
        try await assertRoutedNames(["broken", "healthy"])
    }

    func testChangedConfigurationIgnoresStaleProbeAndDraftFailures() async throws {
        let oldDetail = try await service.get(name: "broken", projectPath: project)
        await service.recordProbeResult(MCPProbeResult(ok: false), for: oldDetail)
        try await service.add(spec: spec("broken", command: "/new/command"), scope: .user, projectPath: nil)
        await service.recordProbeResult(MCPProbeResult(ok: false), for: oldDetail)
        try await assertRoutedNames(["broken", "healthy"])
        _ = await service.probe(spec: spec("healthy", command: "/missing/draft-command"))
        try await assertRoutedNames(["broken", "healthy"])
    }

    func testRecoveryDoesNotOverrideProjectDisableOrDisableAll() async throws {
        let detail = try await service.get(name: "broken", projectPath: project)
        await service.recordProbeResult(MCPProbeResult(ok: false), for: detail)
        try await service.setProjectOverride(name: "broken", projectPath: project, override: .disabled)
        await service.recordProbeResult(MCPProbeResult(ok: true), for: detail)
        try await assertRoutedNames(["healthy"])
        let overrides = await service.codexConfigOverrides(projectPath: project, disableAllServers: true)
        XCTAssertFalse(overrides.contains { $0.contains("enabled=true") })
    }

    func testRemovedServerDoesNotRetainFailureWhenReadded() async throws {
        let detail = try await service.get(name: "broken", projectPath: project)
        await service.recordProbeResult(MCPProbeResult(ok: false), for: detail)
        try await service.remove(name: "broken", scope: .user)
        try await service.add(spec: spec("broken"), scope: .user, projectPath: nil)
        try await assertRoutedNames(["broken", "healthy"])
    }

    func testHTTPProbeFailuresPreserveStatusAndAuthenticationRequirement() async throws {
        let url = try XCTUnwrap(URL(string: "https://mcp-probe.example/mcp"))
        for status in [202, 204, 401, 403, 404, 500] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let failure = await service.httpFailure(response)
            if status < 300 {
                XCTAssertNil(failure)
            } else {
                XCTAssertEqual(failure?.ok, false)
                XCTAssertTrue(failure?.error?.contains("HTTP \(status)") == true)
                XCTAssertEqual(failure?.requiresAuthentication, status == 401)
            }
        }
        let challenged = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 403, httpVersion: nil,
            headerFields: ["WWW-Authenticate": "Bearer"]
        ))
        let failure = await service.httpFailure(challenged)
        XCTAssertEqual(failure?.requiresAuthentication, true)
    }

    private func spec(_ name: String, command: String = "/missing/mcp-routing-test-command") -> MCPServerSpec {
        MCPServerSpec(name: name, command: command)
    }

    private func assertRoutedNames(_ names: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let records = await service.enabledServerRecords(projectPath: project)
        XCTAssertEqual(records.map(\.name).sorted(), names.sorted(), file: file, line: line)
        let acp = await service.acpMCPServers(projectPath: project, bridgeCommand: bridge)
        let acpNames = acp.compactMap { entry -> String? in
            guard case .string(let name) = entry["name"] else { return nil }
            return name
        }
        XCTAssertEqual(acpNames.sorted(), (names + ["rxcode-ide"]).sorted(), file: file, line: line)
        let path = await service.writeClaudeConfig(projectPath: project, bridgeCommand: bridge)
        let data = try Data(contentsOf: URL(filePath: XCTUnwrap(path)))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.keys.sorted(), (names + ["rxcode-ide"]).sorted(), file: file, line: line)
        let codex = await service.codexConfigOverrides(projectPath: project, bridgeCommand: bridge)
        for name in ["broken", "healthy", "rxcode-ide"] {
            let entry = try XCTUnwrap(codex.first { $0.hasPrefix("mcp_servers.\(name)=") })
            XCTAssertEqual(entry.contains("enabled=true"), names.contains(name) || name == "rxcode-ide", file: file, line: line)
        }
    }
}
