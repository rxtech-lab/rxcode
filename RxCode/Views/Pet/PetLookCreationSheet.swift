import Observation
import RxCodeChatKit
import RxCodeCore
import SwiftUI

@MainActor @Observable
final class PetLookPreviewState {
    var motion: PetMotion = .idle
    var replay = UUID()
    var isPlaying = true
    var frame: Double = 0
    var mouth: Mouth = .automatic
    enum Mouth: String, CaseIterable { case automatic, closed, open }
}

struct PetLookCreationSheet: View {
    @Bindable var session: PetLookCreationSession
    let controller: PetController
    let didSave: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var window = WindowState()
    @State private var bridge = ChatBridge()
    @State private var cloudModels: [FlowcyMediaModel] = []
    @State private var turn: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ChatView(
                    showsStatusLine: false,
                    inputAccessory: { modelControls },
                    bottomAccessory: { EmptyView() },
                    aboveInputAccessory: { EmptyView() }
                )
                if let draft = session.draft {
                    ClaudeThemeDivider()
                    PetLookPreview(look: draft, playback: session.preview)
                        .padding()
                        .frame(width: 280)
                        .accessibilityIdentifier("pet-look-inline-preview")
                }
            }
            .padding(.top, 52)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
                Text("Create Pet Look").font(.headline)
                Spacer()
                if let draft = session.draft, !controller.looks.isBuiltin(draft.id) {
                    Button("Save & Use") {
                        do { try controller.looks.save(draft); didSave(); dismiss() }
                        catch { session.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isRunning)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.bar)
        }
        .environment(window)
        .environment(bridge)
        .frame(minWidth: session.draft == nil ? 640 : 940, idealWidth: session.draft == nil ? 760 : 1040, maxWidth: .infinity, minHeight: 620, idealHeight: 760, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if session.isRunning {
                HStack { ProgressView().controlSize(.small); Text(session.status).font(.caption) }
                    .padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 58).allowsHitTesting(false)
            }
        }
        .alert("Unable to Create Look", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .task {
            bridge.sendHandler = {
                guard !session.isRunning else { return }
                let text = window.inputText
                let attachments = window.attachments
                window.inputText = ""
                window.attachments = []
                startTurn(text, attachments: attachments)
            }
            bridge.cancelStreamingHandler = { turn?.cancel(); session.cancel() }
            bridge.enqueueMessageHandler = { text, attachments in window.enqueueMessage(text: text, attachments: attachments) }
            bridge.removeQueuedMessageHandler = { id in window.messageQueue.removeAll { $0.id == id } }
            bridge.sendQueuedNowHandler = { id in
                guard let index = window.messageQueue.firstIndex(where: { $0.id == id }) else { return }
                let queued = window.messageQueue.remove(at: index)
                turn?.cancel(); session.cancel()
                startTurn(queued.text, attachments: queued.attachments)
            }
            bridge.sendAllQueuedAsOneHandler = {
                let queued = window.messageQueue
                guard !queued.isEmpty else { return }
                window.messageQueue = []
                turn?.cancel(); session.cancel()
                startTurn(queued.map(\.text).joined(separator: "\n\n"), attachments: queued.flatMap(\.attachments))
            }
            synchronize()
            guard appState.rxAuth.isAuthenticated else { return }
            do { cloudModels = try await FlowcyMediaClient(auth: appState.rxAuth).allModels() }
            catch is CancellationError { }
            catch { session.error = error.localizedDescription }
        }
        .onChange(of: session.messages) { _, _ in synchronize() }
        .onChange(of: session.isRunning) { _, running in
            synchronize()
            if !running, session.error == nil, !window.messageQueue.isEmpty {
                let queued = window.messageQueue.removeFirst()
                startTurn(queued.text, attachments: queued.attachments)
            }
        }
        .onChange(of: session.chatAgent) { _, _ in synchronize() }
        .onDisappear { turn?.cancel(); session.close() }
    }

    private var modelControls: some View {
        HStack {
            Menu {
                Button("General Agent Default") { session.chatAgent = nil }
                ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                    Section(section.title) {
                        ForEach(section.models.filter { appState.localStudioKind($0.id, provider: $0.provider) == .chat }, id: \.key) { model in
                            Button(model.displayName) {
                                session.chatAgent = TaskAgentConfig(provider: model.provider, model: model.id)
                            }
                        }
                    }
                }
            } label: {
                Label(session.chatAgent.map { appState.taskAgentLabel($0) } ?? "General Agent", systemImage: "bubble.left.and.bubble.right")
                    .lineLimit(1)
            }
            MediaModelMenu(kind: .image, selection: $session.imageSelection, appState: appState, cloudModels: cloudModels)
        }
        .disabled(session.isRunning)
    }

    private func startTurn(_ text: String, attachments: [Attachment]) {
        let previous = turn
        turn = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await session.send(text, attachments: attachments, controller: controller)
        }
    }

    private func synchronize() {
        bridge.messages = session.messages
        bridge.isStreaming = session.isRunning
        bridge.agentProvider = session.chatAgent?.provider ?? controller.configuration.customAgent?.provider ?? appState.selectedAgentProvider
    }
}

struct PetLookPreview: View {
    let look: PetLook
    @Bindable var playback: PetLookPreviewState

    @MainActor
    init(look: PetLook, playback: PetLookPreviewState? = nil) {
        self.look = look
        self.playback = playback ?? PetLookPreviewState()
    }

    private var state: PetState {
        var state = PetState()
        state.motion = playback.motion
        state.isWalking = playback.motion == .walking
        return state
    }

    var body: some View {
        VStack(spacing: 16) {
            PetSpriteView(character: look.character, state: state, size: 180,
                          isAnimationActive: playback.isPlaying, previewFrameIndex: playback.isPlaying ? nil : Int(playback.frame),
                          previewMouthOpen: playback.mouth == .automatic ? nil : playback.mouth == .open)
                .id("\(look.id)-\(playback.motion.rawValue)-\(playback.replay)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Picker("Pose", selection: $playback.motion) {
                ForEach(PetMotion.allCases.filter { $0 != .automatic }) { pose in
                    Text(pose.rawValue.capitalized).tag(pose)
                }
            }
            Picker("Mouth", selection: $playback.mouth) {
                Text("Automatic").tag(PetLookPreviewState.Mouth.automatic)
                Text("Closed").tag(PetLookPreviewState.Mouth.closed)
                Text("Open").tag(PetLookPreviewState.Mouth.open)
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Play", isOn: $playback.isPlaying).toggleStyle(.button)
                Button("Replay", systemImage: "arrow.clockwise") { playback.isPlaying = true; playback.replay = UUID() }
            }
            if !playback.isPlaying {
                Slider(value: $playback.frame, in: 0...Double(max(1, look.columns * (look.sheetCount ?? 1) - 1)), step: 1)
                    .accessibilityLabel("Animation frame")
                Text("Frame \(Int(playback.frame) + 1) · Sheet \(Int(playback.frame) / max(1, look.columns) + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
