import Foundation
import AppKit
import SwiftUI
import XCTest
import RxCodeCore
@testable import RxCode

final class ACPServiceSuggestionTests: XCTestCase {
    func testFailedBootstrapCanBeRetriedOnSameThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-acp-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                response = {"result": {"protocolVersion": 1}}
            elif method == "session/new":
                response = {"error": {"code": -32603, "message": "Internal error",
                    "data": {"message": "Failed to initialize session services"}}}
            else:
                sys.exit(2)
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], **response}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = ACPService()
        let spec = ACPClientSpec(displayName: "Mock Cursor", launch: .binary(
            path: "/usr/bin/python3", args: ["-u", script.path], env: [:]
        ))
        for _ in 0..<3 {
            let streamId = UUID()
            let stream = await service.send(
                streamId: streamId, prompt: "Hello", cwd: directory.path, sessionId: nil,
                model: nil, spec: spec, permissionMode: .default, clientSessionKey: "pending-retry"
            )
            var failures = 0
            for await event in stream {
                if case .result(let result) = event {
                    XCTAssertTrue(result.isError)
                    failures += 1
                }
            }
            XCTAssertEqual(failures, 1)
            let error = await service.consumeStderr(for: streamId)
            XCTAssertTrue(error?.contains("Failed to initialize session services") == true)
            let count = await service.sessions.count
            XCTAssertEqual(count, 0)
        }
        await service.cleanup()
    }

    func testRetiredProcessCallbacksCannotAffectReplacement() async throws {
        let service = ACPService()
        let pipe = Pipe()
        let spec = ACPClientSpec(displayName: "Mock", launch: .binary(path: "/usr/bin/true", args: [], env: [:]))
        let entry = ACPService.SessionEntry(process: Process(), stdin: pipe.fileHandleForWriting,
                                           spec: spec, cwd: "/tmp", canonicalKey: "retry", isEphemeral: false)
        await service.installTestEntry(entry, key: "retry")
        let retiredGeneration = UUID()
        await service.handleProcessExit(key: "retry", generation: retiredGeneration)
        await service.appendProcessStderr(key: "retry", generation: retiredGeneration, line: "stale stderr")
        let staleFrame = #"{"id":1,"result":{}}"#
        await service.deliverStdoutLine(key: "retry", generation: retiredGeneration,
                                       line: staleFrame, data: Data(staleFrame.utf8))
        let remaining = await service.sessions["retry"]
        XCTAssertEqual(remaining?.generation, entry.generation)
        XCTAssertEqual(remaining?.stderr, "")
        XCTAssertEqual(remaining?.stdoutLineCount, 0)
        await service.cleanup()
    }

    func testCursorUsesInstalledCLIForBrowserLoginAndLogout() async throws {
        let spec = ACPClientSpec(registryId: "cursor", displayName: "Cursor", launch: .binary(
            path: "/nonexistent/installed/cursor-agent", args: ["acp"], env: [:]
        ))
        let service = ACPService()
        let methods = try await service.authMethods(spec: spec, cwd: "/nonexistent")
        XCTAssertEqual(methods.map(\.id), ["cursor_login"])
        guard case .terminal(let command, let args, let env) = methods[0].kind else {
            return XCTFail("Cursor must run CLI login instead of ACP authenticate")
        }
        let login = try await service.terminalLogin(spec: spec, command: command, args: args, env: env)
        XCTAssertEqual(login.executable, "/nonexistent/installed/cursor-agent")
        XCTAssertEqual(login.arguments, ["login"])
        let logout = try await service.cursorTerminalLogout(spec: spec)
        XCTAssertEqual(logout.executable, login.executable)
        XCTAssertEqual(logout.arguments, ["logout"])
        XCTAssertEqual(logout.title, "Sign Out of Cursor")
        XCTAssertFalse(logout.reportToChat)
        XCTAssertEqual(ACPService.terminalLoginCommand(
            executable: "/usr/bin/env", launchArgs: ["cursor-agent", "acp"], extraArgs: [],
            command: "cursor-agent", args: ["login"]
        ), ["/usr/bin/env", "cursor-agent", "login"])
    }

    @MainActor
    func testCursorTerminalAuthRemembersAndClearsSignInAfterCompletion() async throws {
        let appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let spec = ACPClientSpec(registryId: "cursor", displayName: "Cursor", launch: .binary(
            path: "/nonexistent/cursor-agent", args: ["acp"], env: [:]
        ))
        appState.acpClients = [spec]
        let supportsLogout = await appState.acpClientSupportsLogout(spec)
        XCTAssertTrue(supportsLogout)
        _ = try await appState.acpCursorTerminalLogout(id: spec.id)
        XCTAssertNil(appState.acpClients.first?.authMethodId, "Preparing a command must not mark authentication complete")
        await appState.completeACPTerminalLogin(id: spec.id, methodId: "cursor_login")
        XCTAssertEqual(appState.acpClients.first?.authMethodId, "cursor_login")
        await appState.completeACPTerminalLogout(id: spec.id)
        XCTAssertNil(appState.acpClients.first?.authMethodId)
    }

    func testOpenCodeAccountCommandsMatchInstalledMajorVersion() {
        XCTAssertEqual(ACPService.openCodeAccountAuthArguments(version: "1.19.3"), ["console", "login"])
        XCTAssertEqual(ACPService.openCodeAccountAuthArguments(version: "v2.0.1"), ["auth", "login", "opencode"])
        XCTAssertEqual(ACPService.openCodeAccountAuthArguments(version: "2.0.1", action: "logout"), ["auth", "logout", "opencode"])
        XCTAssertEqual(ACPService.openCodeAccountAuthArguments(version: "1.19.3", action: "logout"), ["console", "logout"])
    }

    func testUnknownOpenCodeVersionIsDetectedUsingTheInstalledCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rxcode-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("mock opencode.sh")
        for version in ["1.19.3", "2.0.1"] {
            try """
            if [ "$1" = '--version' ]; then
                printf '%s\\n' '\(version)'
            else
                printf '%s\\n' "$@"
            fi
            """.write(to: script, atomically: true, encoding: .utf8)
            for action in ["login", "logout"] {
                let argv = ACPService.openCodeAccountAuthCommand(
                    argv: ["/bin/sh", script.path, "auth", action, "opencode"], version: nil, action: action
                )
                let process = Process()
                process.executableURL = URL(fileURLWithPath: argv[0])
                process.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(output.split(separator: "\n").map(String.init),
                               ACPService.openCodeAccountAuthArguments(version: version, action: action))
            }
        }
    }

    @MainActor
    func testCompletedOpenCodeAccountLoginIsRemembered() async {
        let appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let spec = ACPClientSpec(registryId: "opencode", displayName: "OpenCode",
                                 launch: .binary(path: "/nonexistent/opencode", args: ["acp"], env: [:]),
                                 extraEnv: ["OPENCODE_API_KEY": "obsolete-test-key", "OTHER_SETTING": "keep"])
        appState.acpClients = [spec]
        await appState.completeACPTerminalLogin(id: spec.id, methodId: "rxcode-opencode-account")
        XCTAssertEqual(appState.acpClients.first?.authMethodId, "rxcode-opencode-account")
        XCTAssertNil(appState.acpClients.first?.extraEnv["OPENCODE_API_KEY"])
        XCTAssertEqual(appState.acpClients.first?.extraEnv["OTHER_SETTING"], "keep")
    }

    func testOpenCodeKeyEntryDoesNotLaunchClientOrFetchCatalog() async throws {
        let spec = ACPClientSpec(
            registryId: "opencode", displayName: "OpenCode",
            launch: .binary(path: "/nonexistent/opencode", args: ["acp"], env: [:])
        )
        let methods = try await ACPService().authMethods(spec: spec, cwd: "/nonexistent")
        XCTAssertEqual(methods.map(\.id), ["rxcode-opencode-account", "rxcode-opencode-api-key", "opencode-login"])
        guard case .terminal(_, let accountArgs, _) = methods[0].kind else {
            return XCTFail("Account sign-in should be the default")
        }
        XCTAssertEqual(accountArgs, ["auth", "login", "opencode"])
        guard case .envVar(let variables, let link) = methods[1].kind else {
            return XCTFail("Direct API-key entry should remain optional")
        }
        XCTAssertEqual(variables.map(\.name), ["OPENCODE_API_KEY"])
        XCTAssertTrue(variables[0].secret)
        XCTAssertEqual(link, "https://opencode.ai/auth")
        guard case .terminal(_, let args, _) = methods[2].kind else {
            return XCTFail("Other providers should retain terminal sign-in")
        }
        XCTAssertEqual(args, ["auth", "login"])
        XCTAssertNil(ACPService.openCodeAuthMethods(for: ACPClientSpec(
            displayName: "Other ACP", launch: .binary(path: "/usr/bin/other", args: [], env: [:])
        )))
    }

    func testOpenCodeTerminalFallbackUsesInstalledPackage() {
        XCTAssertEqual(ACPService.terminalLoginCommand(
            executable: "/usr/bin/env", launchArgs: ["npx", "-y", "opencode-ai@1.19.3", "acp"],
            extraArgs: [], command: "opencode", args: ["auth", "login"]
        ), ["/usr/bin/env", "npx", "-y", "opencode-ai@1.19.3", "auth", "login"])
    }

    @MainActor
    func testOpenCodeSignInDisplaysSecureKeyFieldWithoutRunningClient() async throws {
        let appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let spec = ACPClientSpec(
            registryId: "opencode", displayName: "OpenCode",
            launch: .binary(path: "/nonexistent/opencode", args: ["acp"], env: [:]), authMethodId: "rxcode-opencode-api-key"
        )
        appState.acpClients = [spec]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: ACPSignInSheet(client: spec, isSignedIn: false)
            .environment(appState))
        window.contentView = hostingView
        defer { window.close() }
        func secureField(in view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap { secureField(in: $0) }.first
        }
        for _ in 0..<40 {
            hostingView.layoutSubtreeIfNeeded()
            if secureField(in: hostingView) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let field = try XCTUnwrap(secureField(in: hostingView))
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.stringValue, "")
    }

    func testModelConfigPreservesProviderGroupsAndUngroupedOptions() throws {
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"configOptions":[{"id":"model","category":"model","type":"select","currentValue":"opencode-go/glm-5","options":[
            {"group":"opencode-go","name":"OpenCode Go","options":[{"value":"opencode-go/glm-5","name":"GLM-5"}]},
            {"group":"opencode","name":"OpenCode Zen","options":[{"value":"opencode/glm-5","name":"GLM-5","description":"Pay as you go"}]},
            {"value":"default","name":"Default"}
        ]}]}
        """#.utf8))
        let config = try XCTUnwrap(ACPService.parseModelConfig(from: result))
        XCTAssertEqual(config.currentValue, "opencode-go/glm-5")
        XCTAssertEqual(config.options.map(\.groupId), ["opencode-go", "opencode", nil])
        XCTAssertEqual(config.options.map(\.groupName), ["OpenCode Go", "OpenCode Zen", nil])
        XCTAssertEqual(config.options.map(\.value), ["opencode-go/glm-5", "opencode/glm-5", "default"])
        XCTAssertEqual(config.options[1].description, "Pay as you go")
        XCTAssertEqual(try JSONDecoder().decode(ACPModelConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testOlderPersistedModelOptionsDecodeWithoutGroups() throws {
        let option = try JSONDecoder().decode(ACPModelOption.self, from: Data(#"{"value":"opencode-go/glm-5","name":"OpenCode Go/GLM-5"}"#.utf8))
        XCTAssertNil(option.groupId)
        XCTAssertNil(option.groupName)
        XCTAssertEqual(option.value, "opencode-go/glm-5")
    }

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

    func testTerminalLoginPreparesInteractiveEnvironmentAndLaunch() async throws {
        let service = ACPService()
        let spec = ACPClientSpec(displayName: "Mock ACP", launch: .binary(
            path: "/usr/bin/python3", args: ["acp"], env: ["BASE_VALUE": "base"]
        ), extraEnv: ["BASE_VALUE": "override"])
        let state = try await service.terminalLogin(
            spec: spec, command: nil, args: ["--login"], env: ["AUTH_VALUE": "auth"]
        )
        XCTAssertEqual(state.executable, "/usr/bin/python3")
        XCTAssertEqual(state.arguments, ["acp", "--login"])
        let environment = Dictionary(uniqueKeysWithValues: try XCTUnwrap(state.environment).map {
            let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["BASE_VALUE"], "override")
        XCTAssertEqual(environment["AUTH_VALUE"], "auth")
        XCTAssertFalse(state.reportToChat)
    }

    func testInteractiveAuthRemovesInheritedNoninteractiveFlags() {
        let environment = ACPService.interactiveAuthEnvironment([
            "TERM": "dumb", "CI": "1", "NO_COLOR": "1",
            "TERM_PROGRAM": "external", "TERM_PROGRAM_VERSION": "1",
            "PATH": "/usr/bin", "API_KEY": "test-value"
        ])
        XCTAssertNil(environment["CI"])
        XCTAssertNil(environment["NO_COLOR"])
        XCTAssertNil(environment["TERM_PROGRAM"])
        XCTAssertNil(environment["TERM_PROGRAM_VERSION"])
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["API_KEY"], "test-value")
    }

    @MainActor
    func testEmbeddedLoginConnectsAllStandardStreamsToTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-auth-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("tty-result")
        let script = """
        import os, pathlib, sys
        interactive = all(os.isatty(fd) for fd in (0, 1, 2))
        pathlib.Path(sys.argv[1]).write_text("interactive" if interactive else "not interactive")
        sys.exit(0 if interactive else 1)
        """
        let exited = expectation(description: "Interactive login exits")
        let process = TerminalProcess()
        let terminal = EmbeddedTerminalView(
            executable: "/usr/bin/python3", arguments: ["-c", script, marker.path],
            onProcessTerminated: { code in
                XCTAssertEqual(code, 0)
                exited.fulfill()
            }, process: process
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: terminal)
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            process.terminate()
            window.close()
        }
        await fulfillment(of: [exited], timeout: 15)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "interactive")
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

// Actor-isolated fixture setup keeps production session mutation encapsulated.
extension ACPService {
    func installTestEntry(_ entry: SessionEntry, key: String) {
        sessions[key] = entry
    }
}
