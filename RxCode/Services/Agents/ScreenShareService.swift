import Foundation
import RxCodeCore
import RxCodeSync

/// A viewer is bound to one authenticated pairing and a fresh session ID.
@MainActor
final class ScreenShareService {
    private var peer: String?
    private var session: UUID?
    private var displayID: UInt32?
    private var granted = false
    private var inputSequence: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var lastContact = Date.distantPast
    private var captureTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var policy = AgentRemoteAccessPolicy()

    func apply(_ policy: AgentRemoteAccessPolicy) {
        self.policy = policy
        if !policy.allowsViewing { stop() }
        else if !policy.allowsControl && granted {
            granted = false
            inputTask?.cancel()
            publishState()
        }
    }

    func stop(message: String? = nil) {
        captureTask?.cancel()
        inputTask?.cancel()
        if let peer, let session {
            let state = ScreenShareStatePayload(sessionID: session, status: message == nil ? .stopped : .failed, message: message)
            Task { await MobileSyncService.shared.send(.screenShareState(state), toHex: peer) }
        }
        session = nil
        peer = nil
        granted = false
    }

    private func publishState() {
        guard let peer, let session else { return }
        let state = ScreenShareStatePayload(sessionID: session, status: .active, controlGranted: granted, activeDisplayID: displayID)
        Task { await MobileSyncService.shared.send(.screenShareState(state), toHex: peer) }
    }

    func handle(_ request: ScreenShareRequestPayload, from sender: String) async {
        if request.action == .start {
            guard policy.allowsViewing, ComputerControl.hasScreenRecordingAccess, peer == nil || peer == sender else {
                await MobileSyncService.shared.send(.screenShareState(.init(sessionID: nil, status: .denied,
                    message: "Enable screen sharing and Screen Recording permission on the Mac, and close any other viewer.")), toHex: sender)
                return
            }
            stop()
            let id = UUID()
            peer = sender
            session = id
            displayID = request.displayID
            inputSequence = 0
            acknowledged = 0
            lastContact = .now
            captureTask = Task { await capture(sessionID: id, peer: sender) }
            publishState()
            return
        }
        guard peer == sender, let session, request.sessionID == session else { return }
        lastContact = .now
        switch request.action {
        case .stop: stop()
        case .requestControl, .releaseControl:
            granted = request.action == .requestControl && policy.allowsControl && ComputerControl.hasAccessibilityAccess()
            if !granted { inputTask?.cancel() }
            publishState()
        default: break
        }
    }

    func acknowledge(_ ack: ScreenFrameAckPayload, from sender: String) {
        guard peer == sender, session == ack.sessionID else { return }
        acknowledged = max(acknowledged, ack.seq)
    }

    private func capture(sessionID: UUID, peer: String) async {
        var sequence: UInt64 = 0
        var lastFrame = Date.distantPast
        do {
            while !Task.isCancelled && session == sessionID {
                guard MobileSyncService.shared.isPairedPeer(peer), Date.now.timeIntervalSince(lastContact) < 15 else { stop(); return }
                if sequence <= acknowledged || Date.now.timeIntervalSince(lastFrame) >= 2 {
                    let frame = try await ComputerControl.capture(displayID: displayID, maxDimension: 1024, quality: 0.48, showsCursor: true)
                    guard session == sessionID, !Task.isCancelled, MobileSyncService.shared.isPairedPeer(peer) else { return }
                    displayID = frame.display.id
                    sequence += 1
                    lastFrame = .now
                    await MobileSyncService.shared.send(.screenFrame(.init(sessionID: sessionID, seq: sequence, displayID: frame.display.id,
                        jpeg: frame.jpeg, width: frame.width, height: frame.height)), toHex: peer)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            if session == sessionID { stop(message: error.localizedDescription) }
        }
    }

    func input(_ event: RemoteInputPayload, from sender: String) {
        guard granted, peer == sender, session == event.sessionID, event.seq > inputSequence, event.isWellFormed,
              let displayID else { return }
        inputSequence = event.seq
        let previous = inputTask
        inputTask = Task {
            await previous?.value
            guard !Task.isCancelled, granted, session == event.sessionID, MobileSyncService.shared.isPairedPeer(sender) else { return }
            do {
                let display = try await ComputerControl.display(id: displayID)
                guard !Task.isCancelled, granted, session == event.sessionID else { return }
                let point = ComputerControl.point(fractionX: event.x ?? 0.5, y: event.y ?? 0.5, in: display.frame)
                switch event.kind {
                case .click: try await ComputerControl.click(at: point)
                case .doubleClick: try await ComputerControl.click(at: point, count: 2)
                case .rightClick: try await ComputerControl.click(at: point, button: .right)
                case .move: try ComputerControl.move(to: point)
                case .drag:
                    let end = ComputerControl.point(fractionX: event.toX ?? 0, y: event.toY ?? 0, in: display.frame)
                    try await ComputerControl.drag(from: point, to: end)
                case .scroll: try await ComputerControl.scroll(at: point, dx: Int32(event.deltaX ?? 0), dy: Int32(event.deltaY ?? 0))
                case .text: try await ComputerControl.type(event.text ?? "")
                case .key: try ComputerControl.press(event.key ?? "")
                case .unsupported: break
                }
            } catch { if session == event.sessionID { stop(message: error.localizedDescription) } }
        }
    }
}
