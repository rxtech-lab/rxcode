import Combine
import AppKit
import MusicKit
import RxCodeCore
import SwiftUI
import Testing
import ViewInspector
@testable import RxCode

@MainActor
private final class VolumeTestDevice: PetMusicVolumeControlling {
    var state = PetMusicVolumeState(level: 40, canSet: true, deviceID: 1, deviceName: "Test output", muted: false)
    var writes: [Double] = []
    var rejectWrite = false
    var ignoreWrite = false
    func read() -> PetMusicVolumeState { state }
    func set(_ level: Double, deviceID: UInt32?) throws -> PetMusicVolumeState {
        guard !rejectWrite, deviceID == state.deviceID else { throw IDEToolError.handlerFailed("Device rejected change") }
        writes.append(level)
        if !ignoreWrite { state.level = level }
        return state
    }
}

@MainActor
private final class VolumeTestPlayer: PetMusicPlaying {
    var isPlaying = true
    var stateDescription = "playing"
    var title: String? = "The Room Where It Happens"
    var artist: String? = "Artist"
    var artwork: Artwork? { nil }
    var hasCurrentEntry = true
    var playbackCommands = 0
    func observe(_ change: @escaping @MainActor () -> Void) -> [AnyCancellable] { [] }
    func queue(_ song: Song) { playbackCommands += 1 }
    func clear() { playbackCommands += 1 }
    func play() async throws { playbackCommands += 1 }
    func pause() { playbackCommands += 1 }
    func stop() { playbackCommands += 1 }
}

@MainActor
struct PetMusicVolumeTests {
    @Test func hoverPreservesMetadataAndFitsVisibleContent() throws {
        let controller = PetController()
        let music = PetMusic(controller: controller, player: VolumeTestPlayer(), volumeController: VolumeTestDevice(), currentAuthorizationStatus: { .authorized })
        music.synchronize()
        music.refreshVolume()
        var sizes: [NSSize] = []
        for hovered in [false, true] {
            let view = PetMusicPlayerView(music: music, isHovering: hovered)
            let inspected = try view.inspect()
            #expect(try inspected.find(text: "The Room Where It Happens").string() == "The Room Where It Happens")
            #expect(try inspected.find(text: "Artist").string() == "Artist")
            #expect(try inspected.findAll(ViewType.Button.self).count == 2)
            let rows = inspected.findAll(ViewType.HStack.self)
            for row in rows where (try? row.find(text: "The Room Where It Happens")) != nil {
                #expect(((try? row.opacity()) ?? 1) == 1)
            }
            let volume = try inspected.find(ViewType.HStack.self, where: {
                (try? $0.find(ViewType.Slider.self)) != nil
            })
            #expect(try volume.opacity() == (hovered ? 1 : 0))
            let host = NSHostingView(rootView: view)
            sizes.append(host.fittingSize)
        }
        #expect(sizes[1].height - sizes[0].height == 26)
        #expect(sizes[0].height == 52)
        #expect(sizes[0].width == 250)
        #expect(sizes[1].width == sizes[0].width)
        #expect(sizes[1].height <= 90)
    }

    @Test func readAndAdjustWithoutInterruptingPlayback() async throws {
        let controller = PetController()
        let device = VolumeTestDevice()
        let player = VolumeTestPlayer()
        let music = PetMusic(controller: controller, player: player, volumeController: device, currentAuthorizationStatus: { .authorized },
                             requestAuthorization: { Issue.record("Volume must not request MusicKit authorization"); return false })
        let read = try await music.handle(.object(["action": .string("volume")]))
        #expect(read["structuredContent"]?["volume"] == .number(40))
        #expect(read["structuredContent"]?["volume_scope"] == .string("default_output_device"))
        #expect(read["structuredContent"]?["applied"] == .null)
        let set = try await music.handle(.object(["action": .string("set_volume"), "volume": .number(60)]))
        #expect(set["structuredContent"]?["volume"] == .number(60))
        #expect(set["structuredContent"]?["applied"] == .bool(true))
        _ = try await music.handle(.object(["action": .string("decrease_volume")]))
        #expect(music.volume.level == 55)
        _ = try await music.handle(.object(["action": .string("increase_volume"), "amount": .number(80)]))
        #expect(music.volume.level == 100)
        _ = try await music.handle(.object(["action": .string("decrease_volume"), "amount": .number(100)]))
        #expect(music.volume.level == 0)
        #expect(player.playbackCommands == 0)
        #expect(!music.enabled && !music.showsPlayer)
    }

    @Test func invalidValuesNeverWrite() async {
        let controller = PetController()
        let device = VolumeTestDevice()
        let music = PetMusic(controller: controller, player: VolumeTestPlayer(), volumeController: device, currentAuthorizationStatus: { .authorized })
        for value in [JSONValue.number(-1), .number(101), .number(.nan), .string("quiet"), .null] {
            do {
                _ = try await music.handle(.object(["action": .string("set_volume"), "volume": value]))
                Issue.record("Invalid volume was accepted")
            } catch { }
        }
        do {
            _ = try await music.handle(.object(["action": .string("set_volume")]))
            Issue.record("Missing volume was accepted")
        } catch { }
        #expect(device.writes.isEmpty)
    }

    @Test func unsupportedRejectedAndUnconfirmedWritesReportActualState() async throws {
        let controller = PetController()
        let device = VolumeTestDevice()
        let music = PetMusic(controller: controller, player: VolumeTestPlayer(), volumeController: device, currentAuthorizationStatus: { .authorized })
        device.state.canSet = false
        device.state.unavailableReason = "Hardware controls required"
        var result = try await music.handle(.object(["action": .string("decrease_volume")]))
        #expect(result["isError"] == .bool(true))
        #expect(device.writes.isEmpty)
        device.state.canSet = true
        device.rejectWrite = true
        result = try await music.handle(.object(["action": .string("set_volume"), "volume": .number(20)]))
        #expect(result["structuredContent"]?["volume"] == .number(40))
        #expect(result["structuredContent"]?["applied"] == .bool(false))
        device.rejectWrite = false
        device.ignoreWrite = true
        result = try await music.handle(.object(["action": .string("set_volume"), "volume": .number(20)]))
        #expect(result["isError"] == .bool(true))
        #expect(result["structuredContent"]?["volume"] == .number(40))
        device.state.deviceID = 2
        #expect(!music.setVolume(20, deviceID: 1))
        #expect(music.volume.level == 40)
    }
}
