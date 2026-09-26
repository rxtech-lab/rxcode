import Foundation
import XCTest
import RxCodeCore
@testable import RxCode

final class ACPServiceSuggestionTests: XCTestCase {
    func testLogoutUsesAdvertisedACPCapability() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-acp-logout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("mock_acp.py")
        let marker = directory.appendingPathComponent("logged-out")
        try """
        import json, os, sys

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            request_id = request.get("id")
            if method == "initialize":
                capabilities = {"auth": {"logout": {}}} if os.environ.get("SUPPORTS_LOGOUT") == "1" else {}
                print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {
                    "agentCapabilities": capabilities
                }}), flush=True)
            elif method == "logout":
                open(os.environ["LOGOUT_MARKER"], "w").close()
                print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)

        let service = ACPService()
        func spec(supportsLogout: Bool) -> ACPClientSpec {
            ACPClientSpec(displayName: "Mock ACP", launch: .binary(
                path: "/usr/bin/python3", args: ["-u", script.path], env: [
                    "SUPPORTS_LOGOUT": supportsLogout ? "1" : "0",
                    "LOGOUT_MARKER": marker.path
                ]
            ))
        }

        let unsupported = try await service.supportsLogout(spec: spec(supportsLogout: false), cwd: directory.path)
        XCTAssertFalse(unsupported)
        do {
            try await service.signOut(spec: spec(supportsLogout: false), cwd: directory.path)
            XCTFail("Logout should be rejected without the advertised capability")
        } catch ACPError.protocolMismatch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        let supported = try await service.supportsLogout(spec: spec(supportsLogout: true), cwd: directory.path)
        XCTAssertTrue(supported)
        try await service.signOut(spec: spec(supportsLogout: true), cwd: directory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTerminalLoginUsesInstalledAgentBinary() {
        let executable = "/Applications/RxCode/acp-binaries/opencode/1.18.32/opencode"
        XCTAssertEqual(
            ACPService.terminalLoginCommand(
                executable: executable, launchArgs: ["acp"], extraArgs: [],
                command: "opencode", args: ["auth", "login"]
            ),
            [executable, "auth", "login"]
        )
        XCTAssertEqual(
            ACPService.terminalLoginCommand(
                executable: executable, launchArgs: ["acp"], extraArgs: [],
                command: "/usr/local/bin/opencode", args: ["auth", "login"]
            ),
            ["/usr/local/bin/opencode", "auth", "login"]
        )
    }

    func testOpenCodeLogoutRunsAuthInsteadOfACP() {
        XCTAssertEqual(
            ACPService.openCodeLogoutCommand(
                executable: "/Applications/RxCode/acp-binaries/opencode/opencode",
                launchArgs: ["acp"]
            ),
            ["/Applications/RxCode/acp-binaries/opencode/opencode", "auth", "logout"]
        )
        XCTAssertEqual(
            ACPService.openCodeLogoutCommand(
                executable: "/usr/bin/env",
                launchArgs: ["npx", "-y", "opencode-ai@1.18.32", "acp"]
            ),
            ["/usr/bin/env", "npx", "-y", "opencode-ai@1.18.32", "auth", "logout"]
        )
    }

    func testStandaloneSuggestionUsesSelectedACPModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-acp-suggestion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("mock_acp.py")
        try """
        import json, sys

        def emit(value):
            print(json.dumps(value), flush=True)

        model = "default-model"
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            request_id = request.get("id")
            if method == "initialize":
                emit({"jsonrpc": "2.0", "id": request_id, "result": {}})
            elif method == "session/new":
                emit({"jsonrpc": "2.0", "id": request_id, "result": {
                    "sessionId": "mock-suggestion", "configOptions": [{
                        "id": "model", "category": "model", "type": "select",
                        "currentValue": "default-model", "options": [
                            {"value": "default-model", "name": "Default"},
                            {"value": "chosen-model", "name": "Chosen"}
                        ]
                    }]
                }})
            elif method == "session/set_config_option":
                model = request["params"]["value"]
                emit({"jsonrpc": "2.0", "id": request_id, "result": {}})
            elif method == "session/prompt":
                emit({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {
                        "type": "text", "text": model + ": response"
                    }}
                }})
                emit({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
        """.write(to: script, atomically: true, encoding: .utf8)

        let spec = ACPClientSpec(
            displayName: "Mock ACP",
            launch: .binary(path: "/usr/bin/python3", args: ["-u", script.path], env: [:])
        )
        let service = ACPService()
        let response = await service.generatePlainResponse(
            prompt: "Summarize this task",
            model: "chosen-model",
            spec: spec,
            cwd: directory.path
        )
        XCTAssertEqual(response, "chosen-model: response")
    }
}
