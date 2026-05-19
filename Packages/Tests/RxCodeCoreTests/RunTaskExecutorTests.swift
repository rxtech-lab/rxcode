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

    // MARK: - Make profile

    @Test("Make profile with target only emits `make <target>`")
    func makeProfileTargetOnly() {
        var profile = RunProfile(
            projectId: UUID(),
            name: "build",
            type: .make,
            make: MakeRunConfig(target: "build")
        )
        profile.bash.workingDirectory = ""
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("make 'build'"))
        #expect(!script.contains("-f"))
    }

    @Test("Make profile with non-default Makefile passes -f")
    func makeProfileCustomMakefile() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "build",
            type: .make,
            make: MakeRunConfig(makefile: "BuildScripts/release.mk", target: "all", arguments: "VAR=1 -j4")
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("make -f 'BuildScripts/release.mk' 'all' VAR=1 -j4"))
    }

    @Test("Make profile with empty config emits no main command")
    func makeProfileEmpty() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "empty",
            type: .make,
            make: MakeRunConfig()
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(!script.contains("# --- main ---"))
    }

    // MARK: - Xcode profile

    @Test("Xcode .build emits a single xcodebuild build invocation")
    func xcodeBuildAction() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "Build",
            type: .xcode,
            xcode: XcodeRunConfig(container: "App.xcodeproj", scheme: "App", action: .build)
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("xcodebuild -project 'App.xcodeproj' -scheme 'App' -configuration 'Debug' build"))
        #expect(!script.contains("xcrun simctl"))
        #expect(!script.contains("open -n"))
    }

    @Test("Xcode .run with no destination falls back to macOS open -n launcher")
    func xcodeRunNoDestinationUsesMacLauncher() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "Run",
            type: .xcode,
            xcode: XcodeRunConfig(container: "App.xcodeproj", scheme: "App", action: .run)
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("xcodebuild -project 'App.xcodeproj' -scheme 'App' -configuration 'Debug' build"))
        #expect(script.contains("open -n \"$__rxcode_app\""))
        #expect(!script.contains("xcrun simctl"))
    }

    @Test("Xcode .run with iOS Simulator destination installs and launches via simctl")
    func xcodeRunSimulatorUsesSimctl() {
        let destination = XcodeDestination(
            kind: .iosSimulator,
            platform: "iOS Simulator",
            name: "iPhone 16",
            udid: "ABCD-1234",
            os: "18.0"
        )
        let profile = RunProfile(
            projectId: UUID(),
            name: "Run on iPhone 16",
            type: .xcode,
            xcode: XcodeRunConfig(
                container: "App.xcodeproj",
                scheme: "App",
                action: .run,
                selectedDestination: destination
            )
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("-destination 'platform=iOS Simulator,id=ABCD-1234'"))
        #expect(script.contains("xcrun simctl boot \"$__rxcode_udid\""))
        #expect(script.contains("open -a Simulator"))
        #expect(script.contains("xcrun simctl install \"$__rxcode_udid\" \"$__rxcode_app\""))
        #expect(script.contains("xcrun simctl launch --console-pty \"$__rxcode_udid\" \"$__rxcode_bundle_id\""))
        #expect(!script.contains("open -n \"$__rxcode_app\""))
    }

    @Test("Xcode .run with physical iOS device emits clear unsupported error")
    func xcodeRunDeviceIsUnsupported() {
        let destination = XcodeDestination(
            kind: .iosDevice,
            platform: "iOS",
            name: "My iPhone",
            udid: "ABCD-DEVICE"
        )
        let profile = RunProfile(
            projectId: UUID(),
            name: "Run on device",
            type: .xcode,
            xcode: XcodeRunConfig(
                container: "App.xcodeproj",
                scheme: "App",
                action: .run,
                selectedDestination: destination
            )
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("is not yet supported"))
        #expect(script.contains("xcodebuild -project 'App.xcodeproj' -scheme 'App' -configuration 'Debug' -destination 'platform=iOS,id=ABCD-DEVICE' build"))
        #expect(!script.contains("xcrun simctl"))
    }

    @Test("Legacy free-text destination is still honored when no structured pick")
    func xcodeRunLegacyDestinationHonored() {
        let profile = RunProfile(
            projectId: UUID(),
            name: "Legacy",
            type: .xcode,
            xcode: XcodeRunConfig(
                container: "App.xcodeproj",
                scheme: "App",
                action: .run,
                destination: "platform=macOS,arch=arm64"
            )
        )
        let script = RunTaskExecutor.buildWrapperScript(profile: profile, projectPath: "/p")
        #expect(script.contains("-destination 'platform=macOS,arch=arm64'"))
        #expect(script.contains("open -n \"$__rxcode_app\""))
    }

    // MARK: - XcodeDestination

    @Test("XcodeDestination prefers id over name in xcodebuild argument")
    func xcodeDestinationPrefersId() {
        let d = XcodeDestination(
            kind: .iosSimulator,
            platform: "iOS Simulator",
            name: "iPhone 16",
            udid: "ABCD-1234",
            os: "18.0"
        )
        #expect(d.xcodebuildArgument == "platform=iOS Simulator,id=ABCD-1234")
    }

    @Test("XcodeDestination falls back to name+OS when udid missing")
    func xcodeDestinationFallsBackToName() {
        let d = XcodeDestination(
            kind: .iosSimulator,
            platform: "iOS Simulator",
            name: "iPhone 16",
            os: "18.0"
        )
        #expect(d.xcodebuildArgument == "platform=iOS Simulator,name=iPhone 16,OS=18.0")
    }

    // MARK: - XcodeDestinationParser

    @Test("Parser extracts destinations from the Available section only")
    func parserSkipsIneligible() {
        let output = """
        Available destinations for the "App" scheme:
        \t{ platform:macOS, arch:arm64, id:00006001-001435262693801E, name:My Mac }
        \t{ platform:iOS Simulator, id:ABCD-1234, OS:18.0, name:iPhone 16 }

        Ineligible destinations for the "App" scheme:
        \t{ platform:iOS, name:Generic iOS Device, error:Whatever }
        """
        let parsed = XcodeDestinationParser.parse(output)
        #expect(parsed.count == 2)
        #expect(parsed[0].platform == "macOS")
        #expect(parsed[0].name == "My Mac")
        #expect(parsed[0].arch == "arm64")
        #expect(parsed[1].platform == "iOS Simulator")
        #expect(parsed[1].udid == "ABCD-1234")
        #expect(parsed[1].os == "18.0")
    }

    @Test("Parser classifies Mac Catalyst via variant")
    func parserClassifiesMacCatalyst() {
        let output = """
        Available destinations for the "App" scheme:
        \t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:XYZ, name:My Mac }
        """
        let parsed = XcodeDestinationParser.parse(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .macCatalyst)
    }

    @Test("Parser dedupes by stable id")
    func parserDedupes() {
        let output = """
        Available destinations for the "App" scheme:
        \t{ platform:iOS Simulator, id:ABCD, OS:18.0, name:iPhone 16 }
        \t{ platform:iOS Simulator, id:ABCD, OS:18.0, name:iPhone 16 }
        """
        let parsed = XcodeDestinationParser.parse(output)
        #expect(parsed.count == 1)
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
