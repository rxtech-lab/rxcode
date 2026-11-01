import AVFoundation
import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit

/// The chat surface for a local audio model: a player stage with the
/// selected clip's waveform (and its transcript, for speech recognition
/// models) and a list of every take in the thread beside it.
///
/// Refine puts a speech take's text back in the composer and pins its seed,
/// so a reworded take keeps the same voice.
struct AudioStudioView<Composer: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    private let composer: Composer

    @State private var selection = StudioSelection()
    @State private var statuses: [String: String] = [:]
    @State private var activity: [String: [VideoGenerationActivity]] = [:]
    @State private var composerHeight: CGFloat = 0

    init(@ViewBuilder composer: () -> Composer) {
        self.composer = composer()
    }

    private var takes: [GenerationTake] {
        GenerationTake.takes(from: chatBridge.messages, toolName: LocalStudioKind.audio.toolName ?? "", isStreaming: chatBridge.isStreaming)
    }

    var body: some View {
        let takes = takes
        let selected = selection.take(in: takes)
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if let take = selected {
                        AudioStage(take: take, status: take.toolCall.flatMap { statuses[$0.id] }, bottomInset: composerHeight)
                            .id(take.id)
                            .transition(.opacity)
                    } else {
                        ContentUnavailableView {
                            Label { Text("Make Audio", bundle: .module) } icon: { Image(systemName: "waveform") }
                        } description: {
                            Text("Type what \(chatBridge.modelDisplayName) should say, or attach an audio file to transcribe.", bundle: .module)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, composerHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                composer
                    .frame(maxWidth: 820)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { composerHeight = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !takes.isEmpty {
                Divider()
                StudioTakeList(
                    title: String(localized: "Takes", bundle: .module),
                    takes: takes,
                    activity: selected?.toolCall.flatMap { activity[$0.id] } ?? [],
                    select: { id in withAnimation(.smooth(duration: 0.25)) { selection.selectedID = id } }
                ) { take in
                    AudioTakeRow(take: take, status: take.toolCall.flatMap { statuses[$0.id] })
                        .modifier(StudioRowBackground(isSelected: take.id == selected?.id))
                }
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: takes.isEmpty)
        .studioProgress(statuses: $statuses, activity: $activity)
        .onChange(of: takes.map(\.id)) { old, new in selection.takesChanged(from: old, to: new) }
        .onChange(of: windowState.currentSessionId) { _, _ in
            selection = StudioSelection()
            statuses = [:]
            activity = [:]
        }
    }
}

extension GenerationTake {
    var isTranscription: Bool { string("mode") == "transcription" }
}

// MARK: - Stage

private struct AudioStage: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    @AppStorage(AudioGenerationSettings.storageKey) private var savedSettings = ""

    let take: GenerationTake
    let status: String?
    let bottomInset: CGFloat

    @State private var playback = AudioPlayback()
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.background)
        .overlay(alignment: .center) {
            if copied {
                Label { Text("Copied", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: copied)
        .task(id: take.phase == .ready ? take.path : nil) {
            if take.phase == .ready, let path = take.path {
                await playback.load(URL(fileURLWithPath: path))
            } else {
                playback.unload()
            }
        }
        .onDisappear { playback.pause() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: take.isTranscription ? "text.bubble" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 30, height: 30)
                .background(ClaudeTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(title)
                if let meta = metaLine {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if take.phase == .ready, let path = take.path {
                HStack(spacing: 4) {
                    if take.isTranscription {
                        StudioActionButton(systemImage: "doc.on.doc", help: String(localized: "Copy transcript", bundle: .module)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(take.string("transcript") ?? "", forType: .string)
                            flashCopied()
                        }
                    } else {
                        StudioActionButton(systemImage: "wand.and.stars", help: String(localized: "Refine: reword with the same voice", bundle: .module),
                                           isDisabled: chatBridge.isStreaming) { refine() }
                    }
                    StudioActionButton(systemImage: "folder", help: String(localized: "Show in Finder", bundle: .module)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
    }

    private var title: String {
        if take.isTranscription {
            return take.attachments.first?.name ?? String(localized: "Transcription", bundle: .module)
        }
        return take.prompt.isEmpty ? String(localized: "Untitled take", bundle: .module) : take.prompt
    }

    @ViewBuilder
    private var content: some View {
        switch take.phase {
        case .ready:
            VStack(spacing: 18) {
                AudioPlayerPanel(playback: playback)
                    .frame(maxWidth: 720)
                if take.isTranscription, let transcript = take.string("transcript") {
                    ScrollView {
                        Text(transcript)
                            .font(.system(size: ClaudeTheme.size(14)))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(maxWidth: 720)
                    .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: take.isTranscription ? .top : .center)
        case .generating:
            StudioWorkingScreen(systemImage: take.attachments.isEmpty ? "waveform" : "ear", status: status,
                                startedAt: take.date, tint: ClaudeTheme.textPrimary) {
                Task { await chatBridge.cancelStreaming() }
            }
        case .missing:
            ContentUnavailableView {
                Label { Text("Audio Not Found", bundle: .module) } icon: { Image(systemName: "waveform") }
            } description: {
                Text("The audio file is no longer on this device.", bundle: .module)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label { Text("Couldn't Make Audio", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            } description: {
                Text(take.failureMessage)
                    .lineLimit(6)
                    .textSelection(.enabled)
            } actions: {
                Button {
                    windowState.inputText = take.prompt
                } label: {
                    Label { Text("Edit Text", bundle: .module) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(take.prompt.isEmpty || chatBridge.isStreaming)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let duration = take.double("durationSeconds") { parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
        if let seed = take.int("seed") { parts.append(String(localized: "seed \(seed)", bundle: .module)) }
        if let seconds = take.int("elapsedSeconds") { parts.append(VideoStudioFormat.madeIn(seconds)) }
        if let model = take.string("model") { parts.append(model) }
        if parts.isEmpty, take.phase == .generating { parts.append(chatBridge.modelDisplayName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func refine() {
        windowState.inputText = take.prompt
        if let seed = take.int("seed") {
            var settings = AudioGenerationSettings.decode(savedSettings)
            settings.seed = seed
            savedSettings = settings.encoded
        }
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - Player

/// Plays one clip and reports its position for the scrubber.
@MainActor @Observable
final class AudioPlayback {
    private(set) var levels: [Float] = []
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var position: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func load(_ url: URL) async {
        unload()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        levels = await Self.levels(of: url, bars: 96)
    }

    func unload() {
        pause()
        player = nil
        levels = []
        duration = 0
        position = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    /// Peak level per bar, 0…1, read off the main thread.
    static func levels(of url: URL, bars: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return [] }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return [] }
            let size = max(1, count / bars)
            var levels: [Float] = []
            for bar in 0..<bars {
                let start = bar * size
                guard start < count else { break }
                var peak: Float = 0
                for index in start..<min(count, start + size) { peak = max(peak, abs(channel[index])) }
                levels.append(peak)
            }
            let top = max(levels.max() ?? 1, 0.001)
            return levels.map { $0 / top }
        }.value
    }
}

private struct AudioPlayerPanel: View {
    let playback: AudioPlayback

    var body: some View {
        VStack(spacing: 14) {
            AudioWaveform(levels: playback.levels, progress: playback.duration > 0 ? playback.position / playback.duration : 0) {
                playback.seek(to: $0)
            }
            .frame(height: 96)

            HStack(spacing: 14) {
                Button {
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(ClaudeTheme.accent, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playback.isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module))

                Text(Duration.seconds(playback.position).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer()
                Text(Duration.seconds(playback.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(20)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
    }
}

/// Bars of the clip's levels; played bars take the accent color. Click or
/// drag to seek.
private struct AudioWaveform: View {
    let levels: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let bars = levels.isEmpty ? Array(repeating: Float(0.08), count: 64) : levels
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(bars.count) < progress ? ClaudeTheme.accent : ClaudeTheme.textTertiary.opacity(0.45))
                        .frame(height: max(3, CGFloat(bars[index]) * geometry.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                seek(Double(value.location.x / max(geometry.size.width, 1)))
            })
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Waveform", bundle: .module))
    }
}

// MARK: - List

private struct AudioTakeRow: View {
    let take: GenerationTake
    let status: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: take.isTranscription || !take.attachments.isEmpty ? "text.bubble" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(take.phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent)
                .symbolEffect(.pulse, isActive: take.phase == .generating)
                .frame(width: 40, height: 40)
                .background(ClaudeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(rowTitle)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                StudioTakeStatus(take: take, status: status,
                                 detail: take.double("durationSeconds").map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) })
            }
            Spacer(minLength: 0)
        }
    }

    private var rowTitle: String {
        if take.isTranscription, let transcript = take.string("transcript") { return transcript }
        if !take.prompt.isEmpty { return take.prompt }
        return take.attachments.first?.name ?? String(localized: "Untitled take", bundle: .module)
    }
}
#endif
