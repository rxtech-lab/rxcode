import AppKit
import Combine
import MusicKit
import RxCodeCore
import RxAgentCore
import ScreenCaptureKit
import Synchronization
import Testing
@testable import RxCode

struct PetScreenCaptureTests {
    private static func contentText(_ result: RxCodeCore.JSONValue) -> String {
        guard case .array(let blocks) = result["content"] else { return "" }
        return blocks.compactMap { block -> String? in
            guard case .string(let text) = block["text"] else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func imageCount(_ result: RxCodeCore.JSONValue) -> Int {
        guard case .array(let blocks) = result["content"] else { return 0 }
        return blocks.filter { $0["type"] == .string("image") }.count
    }

    @Test("First requested capture invokes native authorization and checks ScreenCaptureKit even after negative preflight")
    @MainActor
    func authorizationIsRequested() async throws {
        let calls = Mutex<[String]>([])
        let controller = PetController()
        let capture = PetScreenCapture(controller: controller, preflight: { false }, requestAccess: {
            calls.withLock { $0.append("request") }
            return true
        }, loadContent: {
            calls.withLock { $0.append("capture") }
            throw NSError(domain: "CaptureTest", code: 17)
        })
        let result = try await capture.capture(.object([:]))
        #expect(calls.withLock { $0 } == ["request", "capture"])
        #expect(capture.lastRequestGranted == true)
        #expect(capture.permissionIssueMessage == nil)
        #expect(result["isError"] == .bool(true))
        #expect(Self.contentText(result).contains("CaptureTest (17)"))
    }

    @Test("Denied native access returns no visual evidence and an accurate system-settings recovery action")
    @MainActor
    func deniedCapture() async throws {
        let controller = PetController()
        let calls = Mutex<[String]>([])
        let capture = PetScreenCapture(controller: controller, preflight: { false }, requestAccess: {
            calls.withLock { $0.append("request") }
            return false
        }, loadContent: {
            calls.withLock { $0.append("capture") }
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        })
        let result = try await capture.capture(.object([:]))
        #expect(calls.withLock { $0 } == ["request", "capture"])
        #expect(capture.lastRequestGranted == false)
        #expect(capture.permissionIssueMessage?.contains("fully quit and reopen this same app") == true)
        #expect(capture.permissionIssueMessage?.contains(Bundle.main.bundleURL.path) == true)
        #expect(controller.alertErrorMessage == nil)
        #expect(PetScreenCapture.privacySettingsURL.absoluteString.hasSuffix("?Privacy_ScreenCapture"))
        #expect(result["isError"] == .bool(true))
        #expect(result["structuredContent"]?["image_available"] == .bool(false))
        #expect(Self.imageCount(result) == 0)
    }

    @Test("A positive preflight skips another authorization request; capture errors retain their native diagnosis")
    @MainActor
    func authorizedCaptureFailure() async throws {
        let controller = PetController()
        let capture = PetScreenCapture(controller: controller, preflight: { true }, requestAccess: {
            Issue.record("Already authorized capture should not ask for access again")
            return false
        }, loadContent: { throw NSError(domain: "CaptureDeviceUnavailable", code: 99) })
        let result = try await capture.capture(.object([:]))
        #expect(capture.lastRequestGranted == nil)
        #expect(capture.permissionIssueMessage == nil)
        #expect(Self.contentText(result).contains("CaptureDeviceUnavailable (99)"))
    }

    @Test("No-image capture results and error envelopes cannot carry successful vision evidence")
    func failedEvidence() throws {
        let bytes = Data([1, 2, 3, 4])
        let image: RxCodeCore.JSONValue = .object(["type": .string("image"), "data": .string(bytes.base64EncodedString()), "mimeType": .string("image/jpeg")])
        let failure = PetScreenCapture.validatedCaptureResult(.object(["isError": .bool(true), "content": .array([image])]))
        #expect(failure["isError"] == .bool(true))
        #expect(failure["structuredContent"]?["image_available"] == .bool(false))
        let noImage = PetScreenCapture.validatedCaptureResult(PetScreenCapture.text("Request completed"))
        #expect(noImage["isError"] == .bool(true))
        let success = PetScreenCapture.validatedCaptureResult(.object(["content": .array([image])]))
        #expect(success["isError"] == .bool(false))
        #expect(success["structuredContent"]?["image_available"] == .bool(true))
        let harness = try IDEToolHarnessBridge.output(.object(["isError": .bool(true), "content": .array([image])]), title: "Photo")
        #expect(harness.isError)
        #expect(harness.images.isEmpty)
    }

    @Test("Realtime completion preserves nested MCP errors and rejects capture completion without an image")
    func realtimeCaptureFailure() {
        let results: [RxAgentCore.JSONValue] = [
            .object(["isError": .bool(true), "content": .array([])]),
            .object(["content": .array([.object(["type": .string("text"), "text": .string("No screenshot was taken")])])])
        ]
        for result in results {
            let event = PetCodexRealtimeEngine.completedToolEvent(.object([
                "id": .string("photo"), "tool": .string("ide__pet_capture"), "status": .string("completed"), "result": result
            ]))
            guard case .toolCallResult(let id, _, let isError) = event else {
                Issue.record("Expected a tool result")
                continue
            }
            #expect(id == "photo")
            #expect(isError)
        }
    }

    @Test("Dragging while voice connects preserves the loading status")
    @MainActor
    func draggingDuringVoiceConnection() {
        let controller = PetController()
        let status = "Connecting Live Voice…"
        controller.actionStatusOverlayMessage = status
        controller.petState.status = .thinking
        controller.petState.mood = .focused

        // Match the overlay's drag-start, movement, and drag-end callbacks.
        controller.screenCapture.cancel()
        controller.setWalking(true)
        #expect(controller.actionStatusOverlayMessage == status)
        controller.setWalking(false)
        controller.screenCapture.cancel()
        #expect(controller.actionStatusOverlayMessage == status)
        #expect(controller.petState.status == .thinking)
        #expect(controller.petState.mood == .focused)
    }

    @Test("MCP JSON bridge preserves numeric display ID 1 and real Booleans")
    func desktopTargetArguments() throws {
        let data = Data(#"{"display_id":1,"x":0.5,"y":0.5,"amount":400,"zero":0,"enabled":true,"disabled":false,"nested":[1,0,true]}"#.utf8)
        let arguments = RxCodeCore.JSONValue.fromAny(try JSONSerialization.jsonObject(with: data))
        #expect(arguments["display_id"] == .number(1))
        #expect(try PetScreenCapture.identifier(arguments["display_id"]) == 1)
        #expect(arguments["zero"] == .number(0))
        #expect(arguments["enabled"] == .bool(true))
        #expect(arguments["disabled"] == .bool(false))
        #expect(arguments["nested"] == .array([.number(1), .number(0), .bool(true)]))
        #expect(try PetDesktopActions.fraction(arguments["x"], fallback: nil) == 0.5)
        #expect(throws: IDEToolError.self) { try PetScreenCapture.identifier(arguments["enabled"]) }
    }

    @Test("Only a display-sized Dock surface may be ignored after an exact AX hit")
    func dockInputCoverage() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let target = CGRect(x: 0, y: 33, width: 1708, height: 1000)
        #expect(PetDesktopDriver.canIgnoreDockSurface(owner: "Dock", layer: 20, frame: display, targetFrame: target, exactAXHit: true))
        #expect(!PetDesktopDriver.canIgnoreDockSurface(owner: "Dock", layer: 20, frame: display, targetFrame: target, exactAXHit: false))
        #expect(!PetDesktopDriver.canIgnoreDockSurface(owner: "Other App", layer: 20, frame: display, targetFrame: target, exactAXHit: true))
        #expect(!PetDesktopDriver.canIgnoreDockSurface(owner: "Dock", layer: 101, frame: display, targetFrame: target, exactAXHit: true))
        #expect(!PetDesktopDriver.canIgnoreDockSurface(owner: "Dock", layer: 20, frame: CGRect(x: 0, y: 900, width: 100, height: 100), targetFrame: target, exactAXHit: true))
    }

    @Test("A focused window on one display need not be first in the desktop window list")
    func focusedDesktopTarget() {
        let frame = CGRect(x: 0, y: 33, width: 1708, height: 1000)
        let target = PetDesktopWindow(id: 40061, pid: 100, app: "Chrome", title: "Repositories", frame: frame, onScreen: true)
        let other = PetDesktopWindow(id: 50000, pid: 200, app: "RxCode", title: "Settings", frame: CGRect(x: 1800, y: 50, width: 700, height: 600), onScreen: true)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [other, target], appFrontmost: true, exactAXWindowFocused: true)?.id == target.id)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [other, target], appFrontmost: false, exactAXWindowFocused: true) == nil)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [other, target], appFrontmost: true, exactAXWindowFocused: false) == nil)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [other], appFrontmost: true, exactAXWindowFocused: true) == nil)
        let hidden = PetDesktopWindow(id: target.id, pid: target.pid, app: target.app, title: target.title, frame: frame, onScreen: false)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [hidden], appFrontmost: true, exactAXWindowFocused: true) == nil)
        let reused = PetDesktopWindow(id: target.id, pid: 999, app: "Other", title: target.title, frame: frame, onScreen: true)
        #expect(PetDesktopDriver.focusedTarget(target, windows: [reused], appFrontmost: true, exactAXWindowFocused: true) == nil)
    }

    @Test("Live opt-in Chrome focus and scroll dispatch",
          .enabled(if: ProcessInfo.processInfo.environment["RXCODE_PET_SCROLL_WINDOW_ID"] != nil))
    func liveDesktopScroll() async throws {
        let id = try #require(UInt32(ProcessInfo.processInfo.environment["RXCODE_PET_SCROLL_WINDOW_ID"] ?? ""))
        let driver = PetDesktopDriver()
        let authorized = await driver.authorized(prompt: false)
        #expect(authorized, "The test host must already have Accessibility authorization; never prompt during tests.")
        guard authorized else { return }
        let target = try #require(await driver.windows().first { $0.id == id && $0.app == "Google Chrome" })
        let focused = try await driver.focus(target, excluding: [])
        // Match PetDesktopActions' animation/input-transparency settling interval.
        try await Task.sleep(for: .milliseconds(350))
        try await driver.verifyFocused(focused, excluding: [])
        let point = PetDesktopActions.point(x: 0.5, y: 0.7, frame: focused.frame)
        try await driver.scroll(focused, point: point, direction: "down", amount: 120, excluding: [])
        print("Live Chrome scroll input dispatched to window_id=\(id); content movement needs separate visual verification.")
    }

    @Test("Off-screen Chrome coordinates may differ while title, profile suffix and size identify the restored window")
    func offScreenWindowMatching() {
        let target = PetDesktopWindow(id: 40061, pid: 100, app: "Google Chrome", title: "Home / X",
                                      frame: CGRect(x: -1792, y: 33, width: 1708, height: 1000), onScreen: false)
        let candidate = PetDesktopDriver.WindowCandidate(title: "Home / X - Google Chrome - Profile",
                                                        frame: CGRect(x: 0, y: 33, width: 1708, height: 1000))
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [candidate]) == 0)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [candidate, candidate]) == nil)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [.init(title: "Different - Google Chrome", frame: candidate.frame)]) == nil)
        let visible = PetDesktopWindow(id: target.id, pid: target.pid, app: target.app, title: target.title, frame: target.frame, onScreen: true)
        #expect(PetDesktopDriver.matchingWindowIndex(target: visible, candidates: [candidate]) == nil)
    }

    @Test("AX window matching tolerates Chrome title differences but rejects ambiguous or moved windows")
    func accessibleWindowMatching() {
        let frame = CGRect(x: 0, y: 33, width: 1708, height: 1000)
        let target = PetDesktopWindow(id: 40061, pid: 100, app: "Google Chrome", title: "rxtech-lab repositories", frame: frame, onScreen: true)
        let chrome = PetDesktopDriver.WindowCandidate(title: "rxtech-lab repositories - Google Chrome", frame: frame)
        let other = PetDesktopDriver.WindowCandidate(title: target.title, frame: CGRect(x: 200, y: 100, width: 900, height: 700))
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [other, chrome]) == 1)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [.init(title: "", frame: frame)]) == 0)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [chrome, chrome]) == nil)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [other]) == nil)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [.init(title: target.title, frame: nil)]) == nil)
        let exact = PetDesktopDriver.WindowCandidate(title: target.title, frame: frame)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [chrome, exact]) == 1)
        #expect(PetDesktopDriver.matchingWindowIndex(target: target, candidates: [exact, exact]) == nil)
    }

    @Test("Capture IDs reject invalid and overflowing values without trapping")
    func identifiers() throws {
        #expect(try PetScreenCapture.identifier(nil) == nil)
        #expect(try PetScreenCapture.identifier(.number(42)) == 42)
        for value in [RxCodeCore.JSONValue.number(-1), .number(0), .number(1.5), .number(.infinity), .number(Double(UInt32.max) + 1), .string("42")] {
            #expect(throws: IDEToolError.self) { try PetScreenCapture.identifier(value) }
        }
    }

    @Test("Quartz to AppKit conversion preserves negative offsets and point sizes")
    func coordinates() {
        let left = CGRect(x: -1920, y: 200, width: 800, height: 600)
        #expect(PetScreenCapture.appKitRect(left, primaryTop: 1080) == CGRect(x: -1920, y: 280, width: 800, height: 600))
        let above = CGRect(x: 500, y: -900, width: 400, height: 300)
        #expect(PetScreenCapture.appKitRect(above, primaryTop: 1080) == CGRect(x: 500, y: 1680, width: 400, height: 300))
    }

    @Test("Photo destinations stay on the requested offset display and above a window when space allows")
    @MainActor
    func destinations() {
        let visible = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        let size = CGSize(width: 300, height: 300)
        let window = CGRect(x: -1500, y: 100, width: 800, height: 400)
        let origin = PetPanelController.photoOrigin(visibleFrame: visible, panelSize: size, window: window)
        #expect(origin.y == window.maxY + 8)
        #expect(visible.contains(CGRect(origin: origin, size: size)))
        let fullScreen = PetPanelController.photoOrigin(visibleFrame: visible, panelSize: size, window: visible)
        #expect(visible.contains(CGRect(origin: fullScreen, size: size)))
    }

    @Test("Capture tools are discoverable for every provider")
    func discovery() {
        for provider in [AgentProvider.codex, .claudeCode, .acp, .localAgent] {
            let names = Set(IDEToolRegistry.tools(for: provider.staticCapabilities).map(\.name))
            #expect(names.contains("ide__pet_capture"))
            #expect(names.contains("ide__pet_list_capture_targets"))
        }
    }

    @Test("Local conversation receives image attachments and tool errors without base64 text")
    func imageDelivery() throws {
        let bytes = Data([1, 2, 3, 4])
        let result: RxCodeCore.JSONValue = .object(["content": .array([
            .object(["type": .string("text"), "text": .string("Photo of display 42")]),
            .object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(bytes.base64EncodedString())])
        ])])
        let output = try IDEToolHarnessBridge.output(result, title: "Photo")
        #expect(output.text == "Photo of display 42")
        #expect(output.images.count == 1)
        #expect(output.images.first?.data == bytes)
        #expect(output.images.first?.mimeType == "image/jpeg")
        let error = try IDEToolHarnessBridge.output(PetScreenCapture.text("Access denied", isError: true), title: "Photo")
        #expect(error.isError)
        #expect(error.images.isEmpty)
    }
}


@MainActor
private final class TestPetMusicPlayer: PetMusicPlaying {
    var isPlaying = true
    var stateDescription: String { isPlaying ? "playing" : "paused" }
    var title: String? = "A real state snapshot"
    var artist: String? = "Artist"
    var artwork: Artwork? { nil }
    var hasCurrentEntry = true
    var stopCount = 0
    var pauseCount = 0
    var clearCount = 0
    var change: (@MainActor () -> Void)?
    var onPlay: (() -> Void)?
    func observe(_ change: @escaping @MainActor () -> Void) -> [AnyCancellable] { self.change = change; return [] }
    func queue(_ song: Song) {}
    func clear() { clearCount += 1; hasCurrentEntry = false; title = nil }
    func play() async throws {
        onPlay?()
        // Simulate a native play operation that completes despite cancellation.
        try? await Task.sleep(for: .milliseconds(60))
        isPlaying = true
        change?()
    }
    func pause() { pauseCount += 1; isPlaying = false; change?() }
    func stop() { stopCount += 1; isPlaying = false; change?() }
}

struct PetInteractionTests {
    @Test("Linking verifies account access without enabling the pet player")
    @MainActor
    func musicLinking() async throws {
        let controller = PetController()
        controller.configuration.isEnabled = false
        let player = TestPetMusicPlayer()
        let music = PetMusic(controller: controller, player: player, currentAuthorizationStatus: { .authorized },
                             requestAuthorization: { true }, checkConnection: { false })
        let result = try await music.handle(.object(["action": .string("connect")]))
        #expect(music.authorizationStatus == .authorized)
        #expect(music.isLinked)
        #expect(music.canPlayCatalogContent == false)
        #expect(result["structuredContent"]?["linked"] == .bool(true))
        #expect(!music.enabled && !music.showsPlayer && !music.ownsQueue && !music.isBusy)
        #expect(player.stopCount == 0)
        // Status must use the same injected authorization source as connection.
        let status = try await music.handle(.object(["action": .string("status")]))
        #expect(status["structuredContent"]?["linked"] == .bool(true))
    }

    @Test("Account verification failure clears stale linking without stopping owned music")
    @MainActor
    func failedMusicConnection() async {
        let controller = PetController()
        let player = TestPetMusicPlayer()
        let music = PetMusic(controller: controller, player: player, currentAuthorizationStatus: { .authorized },
                             requestAuthorization: { true }, checkConnection: {
            throw URLError(.userAuthenticationRequired)
        })
        music.isLinked = true
        music.canPlayCatalogContent = true
        music.enabled = true
        music.ownsQueue = true
        do {
            _ = try await music.handle(.object(["action": .string("connect")]))
            Issue.record("Account verification should fail")
        } catch { }
        #expect(!music.isLinked && music.canPlayCatalogContent == nil && !music.isBusy)
        #expect(player.stopCount == 0 && music.ownsQueue)
    }

    @Test("Denied linking does not verify the account or start playback")
    @MainActor
    func deniedMusicLinking() async {
        let controller = PetController()
        let music = PetMusic(controller: controller, player: TestPetMusicPlayer(), currentAuthorizationStatus: { .denied },
                             requestAuthorization: { false }, checkConnection: {
            Issue.record("Account check should not run without authorization")
            return true
        })
        do {
            _ = try await music.handle(.object(["action": .string("connect")]))
            Issue.record("Denied linking should fail")
        } catch { }
        #expect(!music.isLinked && !music.isBusy && !music.enabled)
        #expect(music.errorMessage != nil)
    }

    @Test("Music errors surface readable messages instead of Cocoa error codes")
    @MainActor
    func musicErrorDescriptions() {
        let toolError = IDEToolError.handlerFailed("Apple Music access is denied.")
        #expect(toolError.localizedDescription == "Apple Music access is denied.")
        #expect(PetMusic.describe(toolError) == "Apple Music access is denied.")
        #expect(PetMusic.describe(MusicTokenRequestError.developerTokenRequestFailed).contains("App ID"))
        #expect(PetMusic.describe(URLError(.notConnectedToInternet)).contains(NSURLErrorDomain))
    }

    @Test("Off stops only owned music and clears its surface; idle music shows no card")
    @MainActor
    func musicOwnership() async throws {
        let controller = PetController()
        let player = TestPetMusicPlayer()
        let music = PetMusic(controller: controller, player: player, currentAuthorizationStatus: { .authorized })
        _ = await music.off()
        #expect(player.stopCount == 0)
        #expect(player.isPlaying)
        music.enabled = true
        #expect(!music.showsPlayer)
        music.ownsQueue = true
        #expect(music.showsPlayer)
        #expect(player.stopCount == 0)
        _ = await music.off()
        #expect(player.stopCount == 2)
        #expect(player.clearCount == 1)
        #expect(!music.enabled && !music.showsPlayer && !music.ownsQueue)
        #expect(!music.isPlaying)
    }

    @Test("Off wins a race with late native playback completion")
    @MainActor
    func latePlaybackCannotRestartAfterOff() async throws {
        let controller = PetController()
        controller.configuration.isEnabled = true
        let player = TestPetMusicPlayer()
        let music = PetMusic(controller: controller, player: player, currentAuthorizationStatus: { .authorized }, requestAuthorization: { true })
        music.ownsQueue = true
        let (started, signal) = AsyncStream<Void>.makeStream()
        player.onPlay = { signal.yield(()); signal.finish() }
        let command = Task { try await music.handle(.object(["action": .string("resume")])) }
        for await _ in started { break }
        _ = await music.off()
        _ = try? await command.value
        #expect(!player.isPlaying)
        #expect(!music.enabled && !music.isBusy)
    }

    @Test("Native player notifications keep metadata and paused status synchronized")
    @MainActor
    func musicExternalUpdates() {
        let controller = PetController()
        let player = TestPetMusicPlayer()
        let music = PetMusic(controller: controller, player: player, currentAuthorizationStatus: { .authorized })
        player.title = "Changed by system controls"
        player.isPlaying = false
        player.change?()
        #expect(music.title == "Changed by system controls")
        #expect(!music.isPlaying)
        #expect(music.playbackState == "paused")
    }

    @Test("Invalid widget updates preserve the previously installed composition")
    @MainActor
    func widgetUpdateIsAtomic() async {
        let controller = PetController()
        let original = JSONUISpec(root: "note", elements: ["note": .init(type: "Text", props: ["text": .string("Review ready")])])
        controller.presentation.widget = original
        do {
            _ = try await controller.presentation.setWidget(.object(["operation": .string("update"), "elements": .object(["note": .null])]))
            Issue.record("A missing root should have been rejected")
        } catch { #expect(controller.presentation.widget == original) }
    }

    @Test("Normalized desktop coordinates preserve Retina-independent points across offset displays")
    func desktopCoordinates() throws {
        let target = CGRect(x: -1920, y: -900, width: 1000, height: 800)
        #expect(PetDesktopActions.point(x: 0.25, y: 0.75, frame: target) == CGPoint(x: -1670, y: -300))
        #expect(PetDesktopActions.point(x: 1, y: 1, frame: target) == CGPoint(x: -921, y: -101))
        #expect(try PetDesktopActions.fraction(nil, fallback: 0.5) == 0.5)
        for value in [RxCodeCore.JSONValue.number(-1), .number(1.01), .number(.infinity), .string("0.2")] {
            #expect(throws: IDEToolError.self) { try PetDesktopActions.fraction(value, fallback: nil) }
        }
        let edge = PetDesktopActions.nearestEdge(to: CGPoint(x: -1900, y: -500), frame: target)
        #expect(edge.x == target.minX + 8)
    }

    @Test("No matching capture cannot be reported as a visible image")
    @MainActor
    func missingPhotoIsNotPresentation() async {
        let controller = PetController()
        controller.configuration.isEnabled = true
        do {
            _ = try await controller.presentation.showImage(.object([:]))
            Issue.record("No screenshot should have been presented")
        } catch { #expect(controller.presentation.images.isEmpty) }
        let result = PetScreenCapture.validatedCaptureResult(.object([
            "structuredContent": .object(["capture_id": .string("photo-id")]),
            "content": .array([.object(["type": .string("image"), "data": .string("bytes")])])
        ]))
        #expect(result["structuredContent"]?["capture_id"] == .string("photo-id"))
        #expect(result["structuredContent"]?["displayed_to_user"] == .bool(false))
    }
}
