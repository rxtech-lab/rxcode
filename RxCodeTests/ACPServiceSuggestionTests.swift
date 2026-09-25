import Foundation
import XCTest
import RxCodeCore
@testable import RxCode

final class ACPServiceSuggestionTests: XCTestCase {
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
