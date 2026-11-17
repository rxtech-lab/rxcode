import AppKit
import RxAgentCore
import RxAgentVoice
import RxCodeCore

nonisolated struct PetToolActivity: Equatable, Sendable {
    enum Status: Sendable {
        case running, completed, failed, cancelled
    }

    struct Call: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        var status: Status = .running
        var finishedAt: Date?
    }

    private(set) var calls: [Call] = []
    // Retain hidden calls so late results can still settle pending work.
    private(set) var pending: [String: String] = [:]

    mutating func start(id: String, name: String) {
        guard pending[id] == nil, !calls.contains(where: { $0.id == id }) else { return }
        pending[id] = name
        calls.append(Call(id: id, name: name))
        if calls.count > 3 { calls.removeFirst(calls.count - 3) }
    }

    @discardableResult
    mutating func finish(id: String, isError: Bool, now: Date = .now) -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        if let index = calls.firstIndex(where: { $0.id == id }) {
            calls[index].status = isError ? .failed : .completed
            calls[index].finishedAt = now
        }
        return true
    }

    mutating func hideCalls() {
        calls.removeAll()
    }

    var nextExpiration: Date? {
        calls.compactMap { $0.finishedAt?.addingTimeInterval(30) }.min()
    }

    mutating func removeExpiredCalls(now: Date = .now) {
        calls.removeAll { call in
            guard let finishedAt = call.finishedAt else { return false }
            return now >= finishedAt.addingTimeInterval(30)
        }
    }

    mutating func cancelPending(now: Date = .now, preservingIDECalls: Bool = false) {
        let cancelledIDs = Set(pending.keys.filter { !preservingIDECalls || !$0.hasPrefix("pet-ide-call-") })
        for index in calls.indices where calls[index].status == .running && cancelledIDs.contains(calls[index].id) {
            calls[index].status = .cancelled
            calls[index].finishedAt = now
        }
        pending = pending.filter { !cancelledIDs.contains($0.key) }
    }
}

extension PetController {
    /// IDE execution is authoritative; realtime item notifications can arrive later.
    func withRealtimeIDEToolActivity(
        name: String,
        operation: () async throws -> RxCodeCore.JSONValue
    ) async throws -> RxCodeCore.JSONValue {
        let id = "pet-ide-call-\(UUID().uuidString)"
        handlePetToolEvent(.toolCallStarted(id: id, name: name))
        do {
            let result = try await operation()
            handlePetToolEvent(.toolCallResult(id: id, content: "", isError: result["isError"]?.boolValue == true))
            return result
        } catch {
            handlePetToolEvent(.toolCallResult(id: id, content: "", isError: true))
            throw error
        }
    }

    func hidePreviousToolCalls() {
        toolExpiryTask?.cancel()
        toolExpiryTask = nil
        toolActivity.hideCalls()
        activeToolDescription = nil
        refreshToolSounds()
        refreshPetState()
    }

    private func scheduleToolExpiration() {
        toolExpiryTask?.cancel()
        toolExpiryTask = nil
        guard let deadline = toolActivity.nextExpiration else { return }
        toolExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.toolActivity.removeExpiredCalls()
            self.refreshPetState()
            self.scheduleToolExpiration()
        }
    }

    func handlePetToolEvent(_ event: AgentEvent?) {
        switch event {
        case .toolCallStarted(let id, let name):
            toolActivity.start(id: id, name: PetCodexRealtimeConnectionFriendlyTool.describe(name))
        case .toolCallResult(let id, _, let isError):
            toolActivity.finish(id: id, isError: isError)
        case .turnEnded:
            toolActivity.cancelPending(preservingIDECalls: true)
        case .failed, .none:
            toolActivity.cancelPending()
        default:
            return
        }

        scheduleToolExpiration()
        activeToolDescription = toolActivity.calls.last(where: { $0.status == .running })?.name
        refreshToolSounds()
        refreshPetState()
    }

    nonisolated static func permitsToolSound(enabled: Bool, muted: Bool, speaking: Bool) -> Bool {
        enabled && !muted && !speaking
    }

    func refreshToolSounds() {
        let session = voiceSession
        let blocked = !Self.permitsToolSound(
            enabled: configuration.isEnabled && configuration.playsToolSounds,
            muted: isMuted || session?.isMuted == true,
            speaking: isStandaloneSpeaking || speechPlayback.isActive
                || session?.activity == .agentSpeaking || session?.activity == .userSpeaking
                || !livePartialUserText.isEmpty
        )
        let running = !toolActivity.pending.isEmpty && activeToolDescription != nil
        guard running, !blocked, !AppSupport.isTestProcess else {
            toolSoundTask?.cancel()
            toolSoundTask = nil
            // Let a short tool's cue finish naturally, but stop immediately for mute/speech/settings.
            if blocked {
                toolSounds.stopActivityCue()
                currentHardwareAudioDriver?.stopToolCue()
            }
            return
        }
        guard toolSoundTask == nil else { return }
        toolSoundTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                let mute = self.activeVoiceMode == .codexRealtime && self.currentHardwareAudioDriver == nil
                    ? self.realtimeToolCueMute : nil
                // Local output is outside WebRTC's echo reference. Briefly gate capture
                // for the cue so it cannot become a false user turn; never change user mute.
                mute?(true)
                defer { mute?(self.voiceSession?.isMuted ?? true) }
                if let driver = self.currentHardwareAudioDriver {
                    driver.playToolCue()
                } else {
                    // WebRTC owns its audio graph; use the default output alongside that graph.
                    let device = self.activeVoiceMode == .codexRealtime ? nil : self.configuration.speakerDeviceUID
                    await self.toolSounds.playActivityCue(outputDeviceUID: device)
                }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    mute?(self.voiceSession?.isMuted ?? true)
                    try await Task.sleep(for: .milliseconds(1300))
                } catch { return }
            }
        }
    }

}

/// Sound discovery, decoding, playback and teardown may block on CoreAudio. Keep all
/// sound objects on one serial queue; tool events only enqueue value snapshots.
nonisolated final class PetToolSoundPlayer: Sendable {
    private let queue = DispatchQueue(label: "com.rxlab.RxCode.pet-tool-sounds", qos: .userInitiated)
    private let activityCue: @Sendable (String?) -> Void
    private let stopCue: @Sendable () -> Void
    private let apply: @Sendable (_ isRunning: Bool, _ didFinish: Bool) -> Void

    init(loadingSoundName: String = "Pop", apply: (@Sendable (Bool, Bool) -> Void)? = nil) {
        let sounds = Sounds(loadingSoundName: loadingSoundName)
        self.activityCue = { sounds.playActivityCue(outputDeviceUID: $0) }
        self.stopCue = { sounds.stopActivityCue() }
        if let apply {
            self.apply = apply
        } else {
            self.apply = { sounds.update(isRunning: $0, didFinish: $1) }
        }
    }

    func update(isRunning: Bool, didFinish: Bool) {
        queue.async { [apply] in apply(isRunning, didFinish) }
    }

    func playActivityCue(outputDeviceUID: String?) async {
        // The capture gate must cover actual playback startup, including a busy CoreAudio queue.
        await withCheckedContinuation { continuation in
            queue.async { [activityCue] in
                activityCue(outputDeviceUID)
                continuation.resume()
            }
        }
    }

    func stopActivityCue() {
        queue.async { [stopCue] in stopCue() }
    }

    deinit {
        // The queued closure owns the sounds until stop and destruction finish off-main.
        queue.async { [apply, stopCue] in apply(false, false); stopCue() }
    }

    /// Only touched by the player's serial queue, including final release.
    private final class Sounds: @unchecked Sendable {
        private let loadingSoundName: String
        private var loading: NSSound?
        private var done: NSSound?
        private var activity: NSSound?

        init(loadingSoundName: String) {
            self.loadingSoundName = loadingSoundName
        }

        func playActivityCue(outputDeviceUID: String?) {
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard activity?.isPlaying != true else { return }
            // Own the sound rather than mutating NSSound's shared named instance.
            if activity == nil {
                activity = NSSound(named: NSSound.Name("Pop"))?.copy() as? NSSound
                activity?.volume = 0.18
                activity?.loops = false
            }
            activity?.playbackDeviceIdentifier = outputDeviceUID
            activity?.play()
        }

        func stopActivityCue() {
            activity?.stop()
        }

        func update(isRunning: Bool, didFinish: Bool) {
            dispatchPrecondition(condition: .notOnQueue(.main))
            if isRunning {
                if loading == nil {
                    loading = NSSound(named: NSSound.Name(loadingSoundName))
                    loading?.volume = 0.12
                    loading?.loops = true
                }
                if loading?.isPlaying == false { loading?.play() }
            } else {
                loading?.stop()
                loading = nil
            }
            if didFinish {
                if done == nil {
                    done = NSSound(named: NSSound.Name("Glass"))
                    done?.volume = 0.2
                }
                done?.stop()
                done?.play()
            }
        }
    }
}
