import Foundation
import Testing
@testable import RxCodeCore

@Suite("RunTaskExecutor helpers")
struct RunTaskExecutorTests {

    // MARK: - Working directory

    @Test("Absolute path is standardized and returned as-is")
    func absolutePathPassesThrough() {
        let result = RunTaskExecutor.resolveWorkingDirectory("/tmp/foo/../foo", projectPath: "/var/project")
        #expect(result == "/tmp/foo")
    }

    @Test("Tilde-prefixed path expands to home directory")
    func tildeExpands() {
        let result = RunTaskExecutor.resolveWorkingDirectory("~/Desktop", projectPath: "/var/project")
        let home = NSHomeDirectory()
        #expect(result == "\(home)/Desktop")
    }

    @Test("Relative path joins onto project path")
    func relativeJoinsOnProject() {
        let result = RunTaskExecutor.resolveWorkingDirectory("./scripts", projectPath: "/Users/me/repo")
        #expect(result == "/Users/me/repo/scripts")
    }

    @Test("Empty string falls back to project path")
    func emptyFallsBackToProject() {
        let result = RunTaskExecutor.resolveWorkingDirectory("", projectPath: "/Users/me/repo")
        #expect(result == "/Users/me/repo")
    }

    @Test("Whitespace-only string falls back to project path")
    func whitespaceFallsBackToProject() {
        let result = RunTaskExecutor.resolveWorkingDirectory("   ", projectPath: "/Users/me/repo")
        #expect(result == "/Users/me/repo")
    }

    // MARK: - Environment resolution

    @Test("Nil preset returns base environment unchanged")
    func nilPresetReturnsBase() {
        let result = RunTaskExecutor.resolveEnvironment(
            preset: nil,
            projectPath: "/p",
            baseEnvironment: ["PATH": "/usr/bin"]
        )
        #expect(result == ["PATH": "/usr/bin"])
    }

    @Test("Manual KV preset overlays on top of base")
    func manualKVOverlays() {
        let preset = EnvironmentPreset(
            name: "dev",
            useManualKV: true,
            manualVars: [
                EnvVar(key: "NODE_ENV", value: "development"),
                EnvVar(key: "API_URL", value: "http://localhost"),
            ]
        )
        let result = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: "/p",
            baseEnvironment: ["PATH": "/usr/bin", "NODE_ENV": "stale"]
        )
        #expect(result["PATH"] == "/usr/bin")
        #expect(result["NODE_ENV"] == "development")
        #expect(result["API_URL"] == "http://localhost")
    }

    @Test("File-only preset loads values via injected loader")
    func fileOnlyLoadsFromInjectedLoader() {
        let preset = EnvironmentPreset(
            name: "dev",
            loadFromFile: true,
            envFilePath: ".env",
            useManualKV: false
        )
        let loader: (String) -> String? = { path in
            #expect(path == "/p/.env")
            return "FROM_FILE=yes\nNODE_ENV=production"
        }
        let result = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: "/p",
            baseEnvironment: ["PATH": "/usr/bin"],
            fileLoader: loader
        )
        #expect(result["FROM_FILE"] == "yes")
        #expect(result["NODE_ENV"] == "production")
        #expect(result["PATH"] == "/usr/bin")
    }

    @Test("Both: manual KV overrides values loaded from file")
    func manualOverridesFile() {
        let preset = EnvironmentPreset(
            name: "dev",
            loadFromFile: true,
            envFilePath: ".env",
            useManualKV: true,
            manualVars: [EnvVar(key: "NODE_ENV", value: "test")]
        )
        let loader: (String) -> String? = { _ in "NODE_ENV=development\nOTHER=1" }
        let result = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: "/p",
            baseEnvironment: [:],
            fileLoader: loader
        )
        #expect(result["NODE_ENV"] == "test")
        #expect(result["OTHER"] == "1")
    }

    @Test("Missing .env file is silently ignored — no throw")
    func missingFileIsIgnored() {
        let preset = EnvironmentPreset(
            name: "dev",
            loadFromFile: true,
            envFilePath: "nope.env",
            useManualKV: false
        )
        let result = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: "/p",
            baseEnvironment: ["PATH": "/usr/bin"],
            fileLoader: { _ in nil }
        )
        #expect(result == ["PATH": "/usr/bin"])
    }

    @Test("Manual var with empty key is dropped")
    func emptyKeyDropped() {
        let preset = EnvironmentPreset(
            name: "dev",
            useManualKV: true,
            manualVars: [
                EnvVar(key: "", value: "x"),
                EnvVar(key: "  ", value: "y"),
                EnvVar(key: "GOOD", value: "z"),
            ]
        )
        let result = RunTaskExecutor.resolveEnvironment(
            preset: preset,
            projectPath: "/p",
            baseEnvironment: [:]
        )
        #expect(result == ["GOOD": "z"])
    }

    // MARK: - Wrapper script

    @Test("Script for minimal profile is cd + lifecycle banners + main")
    func minimalScript() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "test",
            bash: BashRunConfig(command: "echo hi")
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/Users/me/repo")
        #expect(script.contains("#!/usr/bin/env bash"))
        #expect(script.contains("set -e"))
        #expect(script.contains("cd '/Users/me/repo'"))
        #expect(script.contains("echo hi"))
        // Trap is always installed so users see a final exit-code banner.
        #expect(script.contains("trap __rxcode_after EXIT"))
        #expect(script.contains("[rxcode] starting"))
        #expect(script.contains("[rxcode] exited with code"))
        #expect(!script.contains("# --- before launch ---"))
    }

    @Test("Before steps appear before main; after steps wrapped in trap")
    func beforeAndAfterOrdering() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "test",
            bash: BashRunConfig(command: "MAIN_CMD"),
            beforeSteps: [
                RunStep(command: "BEFORE_1"),
                RunStep(command: "BEFORE_2"),
            ],
            afterSteps: [RunStep(command: "AFTER_1")]
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        let mainIdx = script.range(of: "MAIN_CMD")!.lowerBound
        let b1 = script.range(of: "BEFORE_1")!.lowerBound
        let b2 = script.range(of: "BEFORE_2")!.lowerBound
        let aFunc = script.range(of: "AFTER_1")!.lowerBound
        let trap = script.range(of: "trap __rxcode_after EXIT")!.lowerBound
        #expect(b1 < b2)
        #expect(b2 < mainIdx)
        #expect(aFunc < trap, "after-step body lives inside __rxcode_after before trap is registered")
        #expect(trap < mainIdx, "trap is registered before main so it fires even on main failure")
    }

    @Test("Empty before/after commands are filtered out — trap still present")
    func emptyStepsFiltered() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "test",
            bash: BashRunConfig(command: "main"),
            beforeSteps: [RunStep(command: ""), RunStep(command: "   ")],
            afterSteps: [RunStep(command: "")]
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        // Trap stays installed so the exit-code banner still prints.
        #expect(script.contains("trap __rxcode_after EXIT"))
        #expect(!script.contains("# --- before launch ---"))
    }

    @Test("Commands are emitted verbatim — user owns their own quoting")
    func commandsEmittedVerbatim() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "test",
            bash: BashRunConfig(command: "echo \"$HOME\" && ls -la")
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("echo \"$HOME\" && ls -la"))
    }

    @Test("Working directory with single quote is properly escaped")
    func cwdWithSingleQuoteEscaped() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "test",
            bash: BashRunConfig(workingDirectory: "/tmp/it's a path")
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("cd '/tmp/it'\\''s a path'"))
    }

    // MARK: - Model round-trip

    @Test("RunProfile JSON round-trips")
    func runProfileRoundTrip() throws {
        // ISO8601 strategy truncates sub-second precision; use a whole-second
        // timestamp so the round-trip is exact.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = RunProfile(
            projectId: UUID(),
            name: "Dev",
            bash: BashRunConfig(
                command: "pnpm dev",
                workingDirectory: "./web",
                environments: [
                    EnvironmentPreset(
                        name: "dev",
                        loadFromFile: true,
                        envFilePath: ".env.local",
                        useManualKV: true,
                        manualVars: [EnvVar(key: "DEBUG", value: "1")]
                    )
                ]
            ),
            beforeSteps: [RunStep(command: "pnpm install")],
            afterSteps: [RunStep(command: "echo done")],
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunProfile.self, from: data)
        #expect(decoded == original)
    }
}
