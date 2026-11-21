import Foundation
import RxAgentVoice
@preconcurrency import WebRTC

// MARK: - Nonisolated WebRTC Peer Connection

nonisolated protocol PetCodexVoicePeer: Sendable {
    func makeOffer() async throws -> String
    func accept(answer: String) async throws
    func setMicrophoneMuted(_ muted: Bool)
    func levels() async -> (input: Double, output: Double)
    func close()
}

nonisolated final class CodexRealtimePeer: NSObject, RTCPeerConnectionDelegate, PetCodexVoicePeer, @unchecked Sendable {
    enum State: Sendable {
        case connected
        case failed
    }

    private static let initializeSSL: Void = { _ = RTCInitializeSSL() }()
    private let factory: RTCPeerConnectionFactory

    private let onStateChange: @Sendable (State) -> Void
    private let lock = NSLock()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var microphoneMuted = true
    private var eventsChannel: RTCDataChannel?
    private var remoteSpeechEnergy = PetRemoteSpeechEnergy()

    init(device: PetRTCDevice? = nil, onStateChange: @escaping @Sendable (State) -> Void) {
        _ = Self.initializeSSL
        factory = device?.makeFactory() ?? RTCPeerConnectionFactory()
        self.onStateChange = onStateChange
        super.init()
    }

    func makeOffer() async throws -> String {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let peerConn = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw VoiceError.unavailable("Failed to create WebRTC peer connection.")
        }

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "googEchoCancellation": "true",
            "googNoiseSuppression": "true",
            "googAutoGainControl": "true",
            "googHighpassFilter": "true",
        ])
        let source = factory.audioSource(with: audioConstraints)
        let micTrack = factory.audioTrack(with: source, trackId: "rxcode-mic")
        lock.withLock {
            micTrack.isEnabled = !microphoneMuted
            audioTrack = micTrack
        }
        peerConn.add(micTrack, streamIds: ["rxcode-pet"])
        let dataChannel = peerConn.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())

        lock.withLock {
            connection = peerConn
            eventsChannel = dataChannel
        }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peerConn.offer(for: constraints) { @Sendable sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? VoiceError.invalidState)
                }
            }
        }

        try await applyDescription(offer, setter: peerConn.setLocalDescription)

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while peerConn.iceGatheringState != .complete && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(45))
        }

        guard let completeSDP = peerConn.localDescription?.sdp else {
            throw VoiceError.invalidState
        }
        return completeSDP
    }

    func accept(answer: String) async throws {
        let peerConn = lock.withLock { connection }
        guard let peerConn else { throw VoiceError.invalidState }
        let desc = RTCSessionDescription(type: .answer, sdp: answer)
        try await applyDescription(desc, setter: peerConn.setRemoteDescription)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        lock.withLock {
            microphoneMuted = muted
            audioTrack?.isEnabled = !muted
        }
    }

    func levels() async -> (input: Double, output: Double) {
        let peerConn = lock.withLock { connection }
        guard let peerConn else { return (0, 0) }
        return await withCheckedContinuation { continuation in
            peerConn.statistics { @Sendable report in
                var result = (input: 0.0, output: 0.0)
                for stat in report.statistics.values {
                    let level = (stat.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                    switch stat.type {
                    case "media-source":
                        result.input = max(result.input, level)
                    case "inbound-rtp" where (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio":
                        self.lock.lock()
                        let audible = self.remoteSpeechEnergy.level(
                            id: stat.id,
                            energy: (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue,
                            duration: (stat.values["totalSamplesDuration"] as? NSNumber)?.doubleValue
                        )
                        self.lock.unlock()
                        result.output = max(result.output, audible)
                    default:
                        break
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    func close() {
        lock.lock()
        let ch = eventsChannel
        let conn = connection
        eventsChannel = nil
        audioTrack = nil
        connection = nil
        lock.unlock()
        ch?.close()
        conn?.close()
    }

    private func applyDescription(
        _ description: RTCSessionDescription,
        setter: (RTCSessionDescription, @escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setter(description) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            onStateChange(.connected)
        case .failed:
            onStateChange(.failed)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
