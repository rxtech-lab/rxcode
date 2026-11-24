import ExtensionFoundation
import ImageIO
import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class AgentExtensionDevelopmentTests: XCTestCase {
    private var root: URL!
    private var state: AppState!
    private let session = "extension-tool-test"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
        state = nil
    }

    private func bindTurn(to workspace: URL) {
        let stream = UUID()
        var turn = SessionStreamState()
        turn.activeStreamId = stream
        turn.isStreaming = true
        state.sessionStates[session] = turn
        state.extensionDevelopmentWorkspaces[stream] = workspace
    }

    private func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> String {
        let result = try await state.ideHandleToolCall(
            name: "ide__\(tool)_extension", arguments: .object(arguments), sessionKey: session
        )
        return try XCTUnwrap(result["content"]?[0]?["text"]?.stringValue)
    }

    func testCreateUsesTurnWorktreeAndPreservesEditsOnRetry() async throws {
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: false)
        bindTurn(to: worktree)
        let arguments = ["name": JSONValue.string("case-converter")]
        let result = try await call("create", arguments)
        let source = worktree.appending(path: ".rxcode/extensions/case-converter/Extension.swift")
        XCTAssertTrue(result.contains("Extension.swift"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ".rxcode").path))
        try "edited".write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await call("create", arguments)
            XCTFail("Creating an existing extension should report the collision.")
        } catch {
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "edited")
        }
    }

    func testUnaffiliatedAndPlanTurnsCannotCreateExtensions() async throws {
        let arguments = ["name": JSONValue.string("unwanted")]
        do {
            _ = try await call("create", arguments)
            XCTFail("A missing chat workspace must be rejected.")
        } catch {}
        bindTurn(to: root)
        state.sessionStates[session]?.planMode = true
        do {
            _ = try await call("create", arguments)
            XCTFail("Plan mode must not write an extension.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ".rxcode").path))
    }

    func testExtensionNamesAndDirectoriesStayWithinWorktree() throws {
        for name in ["../external", "a/b", "", ".hidden", "Uppercase", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try AgentExtensionBuilder.create(in: root, name: name), name)
        }
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appending(path: ".rxcode"), withDestinationURL: other)
        XCTAssertThrowsError(try AgentExtensionBuilder.create(in: root, name: "example"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testTestingBeforeLoadRequiresReload() async throws {
        bindTurn(to: root)
        _ = try await call("create", ["name": .string("example")])
        do {
            _ = try await call("test", ["name": .string("example"), "input": .string("hello")])
            XCTFail("A test must invoke a loaded extension to return an answer.")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("reload"), error.localizedDescription)
        }
    }

    func testEnablementSheetStaysInRequestingChatAndClearsWhenEnabled() async throws {
        bindTurn(to: root)
        let turn = try XCTUnwrap(state.sessionStates[session]?.activeStreamId)
        var observations = 0
        try await state.waitForExtensionEnablement(name: "example", sessionKey: session, turnID: turn) {
            XCTAssertEqual(self.state.extensionEnablementRequests.map(\.sessionKey), [self.session])
            XCTAssertEqual(self.state.extensionEnablementRequests.map(\.name), ["example"])
            observations += 1
            return observations == 2
        }
        XCTAssertTrue(state.extensionEnablementRequests.isEmpty)
    }

    func testCancellingEnablementEndsReload() async throws {
        bindTurn(to: root)
        let turn = try XCTUnwrap(state.sessionStates[session]?.activeStreamId)
        do {
            try await state.waitForExtensionEnablement(name: "example", sessionKey: session, turnID: turn) {
                self.state.extensionEnablementRequests.removeAll()
                return false
            }
            XCTFail("Dismissing the sheet should cancel the pending reload.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cancelled enablement"))
        }
        XCTAssertTrue(state.extensionEnablementRequests.isEmpty)
    }

    func testStaleBuildCannotActivateOrReplaceAnotherWorktree() async throws {
        let identifier = try AgentExtensionBuilder.serviceIdentifier(in: root, name: "example")
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNotEqual(identifier, try AgentExtensionBuilder.serviceIdentifier(in: other, name: "example"))
        let container = root.appending(path: "Contributor.app")
        let contents = container.appending(path: "Contents/Extensions/Service.appex/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": AppExtensionPoint.workspaceServices.id],
            "RxCodeDevelopmentGeneration": "previous"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        do {
            try await AgentExtensionRuntime.shared.reload(
                workspace: root, bundleIdentifier: identifier, container: container, generation: "replacement"
            ) { _ in XCTFail("A stale build must not request enablement.") }
            XCTFail("The runtime must reject a stale product before registering it.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("generation"), error.localizedDescription)
        }
    }

    func testPluginAPICompatibilityFlagsMismatchedAndUndeclaredVersions() {
        XCTAssertEqual(ExtensionPluginAPI.compatibility(of: "1.0", host: "1.0"), .compatible)
        XCTAssertEqual(ExtensionPluginAPI.compatibility(of: "main", host: "1.0"), .mismatch("main"))
        XCTAssertEqual(ExtensionPluginAPI.compatibility(of: nil, host: "main"), .undeclared)
        XCTAssertEqual(ExtensionPluginAPI.compatibility(of: "  ", host: "main"), .undeclared)
        XCTAssertNil(ExtensionPluginAPI.warning(for: .compatible))
        XCTAssertNotNil(ExtensionPluginAPI.warning(for: .mismatch("0.9")))
        #if DEBUG
        XCTAssertEqual(ExtensionPluginAPI.version, "main")
        #else
        XCTAssertEqual(ExtensionPluginAPI.version, ExtensionPluginAPI.releaseVersion)
        #endif
    }

    func testCreateScaffoldsReadmeAndPackagesValidatedIcon() throws {
        _ = try AgentExtensionBuilder.create(in: root, name: "example")
        let folder = root.appending(path: ".rxcode/extensions/example")
        let readme = try String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8)
        XCTAssertTrue(readme.hasPrefix("# example"))
        var resources = try AgentExtensionBuilder.resources(in: root, name: "example")
        XCTAssertEqual(resources.readme.flatMap { String(data: $0, encoding: .utf8) }, readme)
        XCTAssertNil(resources.icon)

        try Data("not a png".utf8).write(to: folder.appending(path: "icon.png"))
        XCTAssertThrowsError(try AgentExtensionBuilder.resources(in: root, name: "example"))

        let png = try XCTUnwrap(Self.png(pixels: 48))
        try png.write(to: folder.appending(path: "icon.png"))
        resources = try AgentExtensionBuilder.resources(in: root, name: "example")
        XCTAssertEqual(resources.icon, png)
        let icns = try XCTUnwrap(AgentExtensionBuilder.icns(fromPNG: png))
        XCTAssertEqual(icns.prefix(4), Data("icns".utf8))
        XCTAssertEqual(icns.count, Int(icns[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
    }

    func testDevelopmentIdentifiersResolveToTheirInstalledContainer() throws {
        let identifier = try AgentExtensionBuilder.serviceIdentifier(in: root, name: "example")
        let container = try XCTUnwrap(AgentExtensionBuilder.developmentContainer(forServiceIdentifier: identifier))
        XCTAssertEqual(container.lastPathComponent, "example.app")
        XCTAssertEqual(container.deletingLastPathComponent().lastPathComponent, String(identifier.dropLast(".service".count)))
        XCTAssertNil(AgentExtensionBuilder.developmentContainer(forServiceIdentifier: "com.example.app.service"))
        XCTAssertNil(AgentExtensionBuilder.developmentContainer(
            forServiceIdentifier: identifier.replacingOccurrences(of: ".example.service", with: ".../x.service")))
    }

    private static func png(pixels: Int) -> Data? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
