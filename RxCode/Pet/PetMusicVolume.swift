import AudioToolbox
import CoreAudio
import Foundation

struct PetMusicVolumeState {
    var level: Double?
    var canSet = false
    var deviceID: AudioDeviceID?
    var deviceName = "Default output"
    var muted: Bool?
    var unavailableReason: String?
}

@MainActor
protocol PetMusicVolumeControlling {
    func read() -> PetMusicVolumeState
    func set(_ level: Double, deviceID: AudioDeviceID?) throws -> PetMusicVolumeState
}

/// MusicKit exposes no per-player gain on macOS. This controls the default
/// output device, including other apps' audio. MusicKit routes such as AirPlay
/// may use a different output and are not controlled here.
@MainActor
final class PetDeviceMusicVolume: PetMusicVolumeControlling {
    private func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    func read() -> PetMusicVolumeState {
        guard let device = defaultDevice() else {
            return PetMusicVolumeState(unavailableReason: "No default audio output device is available.")
        }
        var state = PetMusicVolumeState(deviceID: device)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: name))
        if AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &name) == noErr, let name {
            state.deviceName = name.takeRetainedValue() as String
        }
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: muted))
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr {
            state.muted = muted != 0
        }
        var address = volumeAddress()
        var scalar: Float32 = 0
        size = UInt32(MemoryLayout.size(ofValue: scalar))
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr,
              scalar.isFinite, (0...1).contains(scalar) else {
            state.unavailableReason = "This output device does not expose readable software volume. Use its hardware controls."
            return state
        }
        state.level = Double(scalar) * 100
        var settable: DarwinBoolean = false
        state.canSet = AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        if !state.canSet { state.unavailableReason = "This output device's volume is read-only. Use its hardware controls." }
        return state
    }

    func set(_ level: Double, deviceID: AudioDeviceID?) throws -> PetMusicVolumeState {
        let state = read()
        guard let device = state.deviceID, device == deviceID else {
            throw VolumeError("The audio output changed. Read the new device volume and try again.")
        }
        guard state.canSet, level.isFinite, (0...100).contains(level) else {
            throw VolumeError(state.unavailableReason ?? "Volume must be between 0 and 100 percent.")
        }
        var address = volumeAddress()
        var scalar = Float32(level / 100)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil,
            UInt32(MemoryLayout.size(ofValue: scalar)), &scalar)
        guard status == noErr else { throw VolumeError("The output device rejected the volume change (Core Audio \(status)).") }
        let result = read()
        guard result.deviceID == device else {
            throw VolumeError("The audio output changed during the volume adjustment. Its resulting volume is unverified.")
        }
        return result
    }

    private struct VolumeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
