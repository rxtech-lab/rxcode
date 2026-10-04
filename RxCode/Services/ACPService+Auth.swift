import AppKit
import Foundation
import RxCodeCore
import os

// MARK: - Authentication

extension ACPService {

    static let initializeParams: [String: JSONValue] = [
        "protocolVersion": .number(1),
        "clientCapabilities": .object([
            "fs": .object([
                "readTextFile": .bool(true),
                "writeTextFile": .bool(true)
            ]),
            "terminal": .bool(false),
            "_meta": .object([
                "terminal-auth": .bool(true)
            ])
        ])
    ]

    /// Spawns the agent and reads the sign-in methods it advertises in its
    /// `initialize` response.
    func authMethods(spec: ACPClientSpec, cwd: String) async throws -> [ACPAuthMethod] {
        try await withEphemeralAgent(spec: spec, cwd: cwd, label: "auth-methods", timeout: .seconds(90)) { key in
            let initResult = try await self.sendRequest(key: key, method: "initialize", params: Self.initializeParams)
            return ACPAuthMethod.parse(initializeResult: initResult)
        }
    }

    func supportsLogout(spec: ACPClientSpec, cwd: String) async throws -> Bool {
        try await withEphemeralAgent(spec: spec, cwd: cwd, label: "logout-capability", timeout: .seconds(90)) { key in
            let result = try await self.sendRequest(key: key, method: "initialize", params: Self.initializeParams)
            return ACPAuthMethod.supportsLogout(initializeResult: result)
        }
    }

    func signOut(spec: ACPClientSpec, cwd: String) async throws {
        try await withEphemeralAgent(spec: spec, cwd: cwd, label: "logout", timeout: .seconds(90)) { key in
            let result = try await self.sendRequest(key: key, method: "initialize", params: Self.initializeParams)
            guard ACPAuthMethod.supportsLogout(initializeResult: result) else {
                throw ACPError.protocolMismatch("This client does not support logout.")
            }
            _ = try await self.sendRequest(key: key, method: "logout", params: [:])
        }
    }

    /// Runs the agent-driven `authenticate` flow. The agent may open a
    /// browser, so the timeout leaves room for the user to finish signing in.
    func authenticate(spec: ACPClientSpec, methodId: String, cwd: String) async throws {
        try await withEphemeralAgent(spec: spec, cwd: cwd, label: "authenticate", timeout: .seconds(300)) { key in
            _ = try await self.sendRequest(key: key, method: "initialize", params: Self.initializeParams)
            self.logger.info("[ACP] → authenticate methodId=\(methodId, privacy: .public) client=\(spec.displayName, privacy: .public)")
            _ = try await self.sendRequest(key: key, method: "authenticate", params: ["methodId": .string(methodId)])
        }
    }

    /// OpenCode's terminal login stores provider credentials outside RxCode.
    /// Inspect only the provider entries, never the credential values.
    func hasOpenCodeCredentials() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let providers = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return false }
        return providers.values.contains { $0["type"] is String }
    }

    /// Opens Terminal running the agent's interactive login for a `terminal`
    /// auth method.
    func openTerminalLogin(spec: ACPClientSpec, command: String?, args: [String], env: [String: String]) async throws {
        let (executable, launchArgs, launchEnv) = try resolveLaunch(spec.launch)
        let argv = Self.terminalLoginCommand(
            executable: executable, launchArgs: launchArgs, extraArgs: spec.extraArgs,
            command: command, args: args
        )
        let exports = launchEnv.merging(spec.extraEnv) { _, new in new }.merging(env) { _, new in new }
        try await openTerminalAuthCommand(argv: argv, exports: exports, label: "Login")
    }

    /// OpenCode manages provider credentials outside ACP, so its older ACP
    /// server can only sign out through the interactive CLI provider picker.
    func openOpenCodeTerminalLogout(spec: ACPClientSpec) async throws {
        let (executable, launchArgs, launchEnv) = try resolveLaunch(spec.launch)
        let argv = Self.openCodeLogoutCommand(executable: executable, launchArgs: launchArgs)
        let exports = launchEnv.merging(spec.extraEnv) { _, new in new }
        try await openTerminalAuthCommand(argv: argv, exports: exports, label: "Logout")
    }

    private func openTerminalAuthCommand(argv: [String], exports: [String: String], label: String) async throws {
        let path = await resolvedEnvironment()["PATH"]

        var environment = exports
        if let path { environment["PATH"] = path }
        let exportLines = environment.keys.sorted().compactMap { name -> String? in
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  let value = environment[name] else { return nil }
            return "export \(name)=\(Self.shellQuoted(value))"
        }
        let commandLine = argv.map(Self.shellQuoted).joined(separator: " ")
        let script = (["#!/bin/zsh"] + exportLines + [commandLine]).joined(separator: "\n") + "\n"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RxCode-ACP-\(label)-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw ACPError.protocolMismatch("Could not open Terminal.") }
    }

    static func terminalLoginCommand(
        executable: String, launchArgs: [String], extraArgs: [String],
        command: String?, args: [String]
    ) -> [String] {
        guard let command else { return [executable] + launchArgs + extraArgs + args }
        // A terminal-auth hint may name the agent on PATH even when RxCode
        // installed a different version. Run the same binary used for ACP.
        let resolved = !command.contains("/") && command == URL(fileURLWithPath: executable).lastPathComponent
            ? executable : command
        return [resolved] + args
    }

    static func openCodeLogoutCommand(executable: String, launchArgs: [String]) -> [String] {
        var command = [executable] + launchArgs
        if let acpIndex = command.firstIndex(of: "acp") {
            command = Array(command[..<acpIndex])
        }
        return command + ["auth", "logout"]
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
