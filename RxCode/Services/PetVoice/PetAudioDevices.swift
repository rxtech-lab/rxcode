import AudioToolbox
import CoreAudio
import Foundation
import Observation

// MARK: - CoreAudio Device Discovery & Routing for the Pet

/// A CoreAudio device the pet can capture from or play through, keyed by its persistent UID.
nonisolated struct PetAudioDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool

    var id: String { uid }
}

nonisolated enum PetAudioDevices {
    enum Direction: Sendable {
        case input, output

        var scope: AudioObjectPropertyScope {
            self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        }
    }

    /// Every device currently attached to this Mac, sorted by name.
    static func all() -> [PetAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id -> PetAudioDevice? in
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, of: id) ?? uid
            let input = channelCount(of: id, direction: .input) > 0
            let output = channelCount(of: id, direction: .output) > 0
            guard input || output else { return nil }
            return PetAudioDevice(uid: uid, name: name, hasInput: input, hasOutput: output)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Resolves a persistent UID to the current device ID, or `nil` when it is disconnected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown,
              channelCount(of: deviceID, direction: .input) + channelCount(of: deviceID, direction: .output) > 0 else {
            return nil
        }
        return deviceID
    }

    /// Points an AUHAL I/O unit (an `AVAudioEngine` input or output node) at the chosen device.
    /// A `nil` or disconnected UID leaves the unit on the system default device.
    @discardableResult
    static func route(_ audioUnit: AudioUnit?, toDeviceUID uid: String?, direction: Direction) -> Bool {
        guard let audioUnit, let uid, !uid.isEmpty,
              var deviceID = deviceID(forUID: uid),
              channelCount(of: deviceID, direction: direction) > 0 else { return false }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(of id: AudioObjectID, direction: Direction) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Live Device Catalog

/// Observable list of audio devices that refreshes when hardware is plugged in or removed.
@MainActor
@Observable
final class PetAudioDeviceCatalog {
    private(set) var inputs: [PetAudioDevice] = []
    private(set) var outputs: [PetAudioDevice] = []
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        var address = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    isolated deinit {
        guard let listener else { return }
        var address = Self.devicesAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    func refresh() {
        let devices = PetAudioDevices.all()
        inputs = devices.filter(\.hasInput)
        outputs = devices.filter(\.hasOutput)
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
