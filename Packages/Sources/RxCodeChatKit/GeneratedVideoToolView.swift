import AVKit
import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit
#endif

/// A generated video stays playable in the conversation after the
/// `VideoGeneration` tool completes. While it runs, the card shows the
/// sampler's live progress, which the tool posts as notifications.
struct GeneratedVideoToolView: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    @State private var progress: String?
    @State private var player: AVPlayer?
    @State private var showsPlayer = false
    @State private var startedAt = Date()

    private static let maxWidth: CGFloat = 520
    private static let placeholderHeight: CGFloat = 260

    private enum Phase { case generating, ready, missing, failed }

    private var output: [String: JSONValue] {
        guard let result = toolCall.result, let data = result.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    private var path: String? { output["savedPath"]?.stringValue }

    private var prompt: String? {
        let prompt = output["prompt"]?.stringValue ?? toolCall.input["prompt"]?.stringValue
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prompt
    }

    private var phase: Phase {
        if toolCall.result == nil { return isStreaming ? .generating : .failed }
        if toolCall.isError || path == nil { return .failed }
        return FileManager.default.fileExists(atPath: path ?? "") ? .ready : .missing
    }

    private var failureMessage: String {
        output["displayError"]?.stringValue
            ?? (toolCall.result == nil ? String(localized: "Video generation was stopped") : String(localized: "Video generation failed"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let prompt, phase != .failed {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(prompt)
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .bubbleStyle(phase == .failed ? .toolError : .tool)
        .padding(.vertical, 6)
        .animation(.smooth(duration: 0.3), value: phase)
        #if os(iOS)
        .sensoryFeedback(.success, trigger: phase == .ready)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: VideoGenerationProgress.notification)) { note in
            guard note.userInfo?[VideoGenerationProgress.callIDKey] as? String == toolCall.id,
                  let status = note.userInfo?[VideoGenerationProgress.statusKey] as? String else { return }
            progress = status
        }
        .task(id: path) { loadPlayer() }
        .sheet(isPresented: $showsPlayer) { playerSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: phase == .failed ? "exclamationmark.triangle.fill" : "film")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent)
                .frame(width: 28, height: 28)
                .background(
                    (phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .symbolEffect(.pulse, isActive: phase == .generating)

            VStack(alignment: .leading, spacing: 1) {
                Text("Generated video")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                statusLine
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            if phase == .ready {
                #if os(macOS)
                Button {
                    if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                } label: {
                    Image(systemName: "folder")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                #endif

                Button {
                    player?.pause()
                    showsPlayer = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .help("Open player")
                .accessibilityLabel("Open player")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .generating:
            // Elapsed time keeps moving between the sampler's step updates.
            HStack(spacing: 4) {
                Text(progress ?? String(localized: "Preparing…"))
                Text("·")
                Text(startedAt, style: .timer).monospacedDigit()
            }
        case .ready:
            Text(readyDetail)
        case .missing:
            Text("The video file is no longer on this device")
        case .failed:
            Text("Couldn't generate video")
        }
    }

    private var readyDetail: String {
        var parts: [String] = []
        if let width = output["width"]?.numberValue.map(Int.init), let height = output["height"]?.numberValue.map(Int.init) { parts.append("\(width)×\(height)") }
        if let seconds = output["elapsedSeconds"]?.numberValue.map(Int.init) {
            parts.append(seconds >= 60
                ? String(localized: "made in \(seconds / 60) min \(seconds % 60) s")
                : String(localized: "made in \(seconds) s"))
        }
        if let model = output["model"]?.stringValue { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    .overlay {
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .accessibilityLabel("Generated video player")
            }
        case .generating:
            GeneratingVideoPlaceholder()
                .frame(maxWidth: .infinity)
                .frame(height: Self.placeholderHeight)
                .transition(.opacity)
        case .missing:
            EmptyView()
        case .failed:
            Text(failureMessage)
                .font(.callout)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = output["width"]?.numberValue.map(Int.init), let height = output["height"]?.numberValue.map(Int.init), height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    // MARK: - Player

    private var playerSheet: some View {
        NavigationStack {
            Group {
                if let path {
                    VideoPlayer(player: AVPlayer(url: URL(fileURLWithPath: path)))
                } else {
                    ContentUnavailableView("Video not available", systemImage: "film")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Generated video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showsPlayer = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 900, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        #endif
    }

    private func loadPlayer() {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            player = nil
            return
        }
        player = AVPlayer(url: URL(fileURLWithPath: path))
    }
}

/// Film-strip shimmer shown while a clip renders.
private struct GeneratingVideoPlaceholder: View {
    @State private var phase = false

    var body: some View {
        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
            .fill(ClaudeTheme.surfaceSecondary)
            .overlay {
                LinearGradient(
                    colors: [.clear, ClaudeTheme.accent.opacity(0.12), .clear],
                    startPoint: phase ? .trailing : .leading, endPoint: phase ? .leading : .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            }
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    ProgressView().controlSize(.small)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = true }
            }
            .accessibilityLabel("Generating video")
    }
}
