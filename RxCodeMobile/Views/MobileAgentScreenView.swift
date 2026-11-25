import RxCodeCore
import RxCodeSync
import SwiftUI

@MainActor @Observable
final class MobileAgentScreen {
    var status: ScreenShareStatePayload?
    var image: UIImage?
    var watching = false
    private var frameSequence: UInt64 = 0
    private var inputSequence: UInt64 = 0

    func reset() {
        watching = false
        status = nil
        image = nil
        frameSequence = 0
        inputSequence = 0
    }

    func receive(_ next: ScreenShareStatePayload, state: MobileAppState) {
        guard watching else {
            if next.status == .active, let sessionID = next.sessionID {
                Task { try? await state.sendAgentPayload(.screenShareRequest(.init(action: .stop, sessionID: sessionID))) }
            }
            return
        }
        if let id = status?.sessionID, next.sessionID != id { return }
        status = next
        if next.status != .active { image = nil }
    }

    func receive(_ frame: ScreenFramePayload, state: MobileAppState) {
        guard watching, status?.status == .active, status?.sessionID == frame.sessionID, frame.seq > frameSequence else { return }
        frameSequence = frame.seq
        image = UIImage(data: frame.jpeg)
        Task { try? await state.sendAgentPayload(.screenFrameAck(.init(sessionID: frame.sessionID, seq: frame.seq))) }
    }

    func input(_ kind: RemoteInputPayload.Kind, x: Double? = nil, y: Double? = nil, text: String? = nil,
               key: String? = nil, state: MobileAppState) {
        guard watching, status?.controlGranted == true, let id = status?.sessionID else { return }
        inputSequence += 1
        let event = RemoteInputPayload(sessionID: id, seq: inputSequence, kind: kind, x: x, y: y, text: text, key: key)
        Task { try? await state.sendAgentPayload(.remoteInput(event)) }
    }
}

struct MobileAgentScreenView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var error: String?
    private var screen: MobileAgentScreen { state.agentScreen }

    var body: some View {
        NavigationStack {
            VStack {
                if let image = screen.image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                Color.clear.contentShape(Rectangle()).onTapGesture { point in
                                    if screen.status?.controlGranted == true {
                                        MobileHaptics.buttonTap()
                                        screen.input(.click, x: point.x / geo.size.width, y: point.y / geo.size.height, state: state)
                                    }
                                }
                            }
                        }
                } else if let message = error ?? screen.status?.message {
                    ContentUnavailableView("Screen Unavailable", systemImage: "display", description: Text(message))
                } else if screen.status?.status == .stopped {
                    ContentUnavailableView("Screen Sharing Ended", systemImage: "display")
                } else { ProgressView("Connecting to Mac…") }
                if screen.status?.controlGranted == true {
                    HStack {
                        TextField("Type on Mac", text: $text).textFieldStyle(.roundedBorder)
                        Button("Type") { screen.input(.text, text: text, state: state); text = "" }
                            .disabled(text.isEmpty || text.count > RemoteInputPayload.textLimit)
                        Button("Return") { screen.input(.key, key: "return", state: state) }
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Mac Screen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if state.agentHub.remoteAccess.allowsControl, screen.status?.status == .active {
                    ToolbarItem(placement: .primaryAction) {
                        Button(screen.status?.controlGranted == true ? "Release Control" : "Control") {
                            MobileHaptics.buttonTap()
                            let request = ScreenShareRequestPayload(action: screen.status?.controlGranted == true ? .releaseControl : .requestControl,
                                sessionID: screen.status?.sessionID)
                            Task { try? await state.sendAgentPayload(.screenShareRequest(request)) }
                        }
                    }
                }
            }
        }
        .task {
            screen.reset()
            screen.watching = true
            do {
                try await state.sendAgentPayload(.screenShareRequest(.init(action: .start)))
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    guard let status = screen.status else { error = "The Mac did not respond."; continue }
                    guard status.status == .active else { break }
                    try await state.sendAgentPayload(.screenShareRequest(.init(action: .keepAlive, sessionID: status.sessionID)))
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { dismiss() } }
        .onDisappear {
            let id = screen.status?.sessionID
            let peer = state.pairedDesktopPubkey
            screen.reset()
            if let id { Task { try? await state.client.send(.screenShareRequest(.init(action: .stop, sessionID: id)), toHex: peer) } }
        }
    }
}
