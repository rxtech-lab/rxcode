import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ClaudeLoginTests: XCTestCase {
    func testInteractivePromptFallsBackBeforeProcessExits() async throws {
        let script = try loginScript("print -n 'Paste code here if prompted > '\nexec /bin/sleep 10")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let started = Date()

        do {
            try await makeAppState().claude.runLoginProcess(
                binary: script.path, timeout: .seconds(2),
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected an interactive login fallback")
        } catch ClaudeCodeServer.ClaudeError.interactiveLoginRequired {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        }
    }

    func testUnrecognizedPromptFallsBackOnTimeout() async throws {
        let script = try loginScript("print -n 'Waiting for authorization... '\nexec /bin/sleep 10")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let started = Date()

        do {
            try await makeAppState().claude.runLoginProcess(
                binary: script.path, timeout: .milliseconds(200),
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected a timed login fallback")
        } catch ClaudeCodeServer.ClaudeError.interactiveLoginRequired {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testCompletedBackgroundLoginSucceeds() async throws {
        let script = try loginScript("print 'Login complete'\nexit 0")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        try await makeAppState().claude.runLoginProcess(
            binary: script.path, timeout: .seconds(2),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func loginScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RxCode-ClaudeLoginTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude")
        try "#!/bin/zsh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func makeAppState() -> AppState {
        AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
    }
}
