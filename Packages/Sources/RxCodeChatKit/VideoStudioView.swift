import AVKit
import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit

/// One prompt and the clip the video model made for it, read back from the
/// thread's messages: each user message is a prompt, and the assistant's
/// `VideoGeneration` tool call that follows carries the result.
struct VideoTake: Identifiable, Equatable {
    enum Phase: Equatable { case generating, ready, missing, failed }

    let id: UUID
    let prompt: String
    let date: Date
    let toolCall: ToolCall?
    /// Files the user attached to the prompt, e.g. a start frame.
    var attachments: [AttachmentInfo] = []
    /// Text the model replied with instead of a clip, e.g. for an empty prompt.
    let reply: String?
    let phase: Phase

    var output: [String: JSONValue] {
        guard let result = toolCall?.result, let data = result.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    var path: String? { output["savedPath"]?.stringValue }
    var width: Int? { output["width"]?.numberValue.map(Int.init) }
    var height: Int? { output["height"]?.numberValue.map(Int.init) }
    var elapsedSeconds: Int? { output["elapsedSeconds"]?.numberValue.map(Int.init) }
    var model: String? { output["model"]?.stringValue }
    /// The start frame this clip continued from: recorded by the tool, else
    /// the image attached to the prompt.
    var sourcePath: String? { output["sourcePath"]?.stringValue ?? attachments.first(where: \.isImage)?.path }

    var aspectRatio: CGFloat {
        guard let width, let height, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    var failureMessage: String {
        if let message = output["displayError"]?.stringValue { return message }
        if let reply, !reply.isEmpty { return reply }
        return toolCall == nil
            ? String(localized: "No video was generated", bundle: .module)
            : String(localized: "Video generation was stopped", bundle: .module)
    }

    static func takes(from messages: [ChatMessage], isStreaming: Bool) -> [VideoTake] {
        var takes: [VideoTake] = []
        for (index, message) in messages.enumerated() where message.role == .user && !message.isCompactBoundary {
            let prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // The assistant rows that answer this prompt, up to the next prompt.
            let replies = messages[(index + 1)...].prefix { $0.role != .user }
            let call = replies.lazy.flatMap(\.toolCalls)
                .last { $0.name.lowercased() == VideoGenerationProgress.toolName.lowercased() }
            let reply = replies.map(\.content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let isLast = index == messages.lastIndex { $0.role == .user }
            let phase: Phase
            if let call, call.result != nil {
                let path = (try? JSONDecoder().decode([String: JSONValue].self, from: Data((call.result ?? "").utf8)))?["savedPath"]?.stringValue
                if call.isError || path == nil {
                    phase = .failed
                } else {
                    phase = FileManager.default.fileExists(atPath: path ?? "") ? .ready : .missing
                }
            } else if isLast && isStreaming {
                phase = .generating
            } else {
                phase = .failed
            }
            takes.append(VideoTake(id: message.id, prompt: prompt, date: message.timestamp,
                                   toolCall: call, attachments: message.attachmentPaths,
                                   reply: reply.isEmpty ? nil : reply, phase: phase))
        }
        return takes
    }
}

/// Parsed sampler status: `"Step 3/4 · 12.34s/it"` → 0.75.
enum VideoProgressStatus {
    static func fraction(in status: String?) -> Double? {
        guard let status,
              // Only sampler lines; task model notes and repo names can hold "2/3" too.
              let regex = try? NSRegularExpression(pattern: #"^Step\s+(\d+)\s*/\s*(\d+)"#),
              let match = regex.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)),
              let doneRange = Range(match.range(at: 1), in: status), let totalRange = Range(match.range(at: 2), in: status),
              let done = Double(status[doneRange]), let total = Double(status[totalRange]), total > 0
        else { return nil }
        return min(max(done / total, 0), 1)
    }
}

/// The chat surface for a local video model: a large player stage for the
/// selected clip (or the live render), and a list of every generation in the
/// thread beside it. Replaces the message list while a video model is selected.
struct VideoStudioView<Composer: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    private let composer: Composer

    @State private var selectedID: UUID?
    @State private var fileRevision = 0
    /// Latest sampler status per tool call id, posted by the running tool.
    @State private var statuses: [String: String] = [:]
    /// Every status a tool call posted, oldest first, for the activity popover.
    @State private var activity: [String: [VideoGenerationActivity]] = [:]
    /// Height of the floating composer, so the clip fits above it.
    @State private var composerHeight: CGFloat = 0
    /// Set once a prompt is sent in the open thread, so its render takes over
    /// the stage. Opening a thread shows its latest finished clip instead.
    @State private var followsLatest = false

    init(@ViewBuilder composer: () -> Composer) {
        self.composer = composer()
    }

    private var takes: [VideoTake] {
        _ = fileRevision
        return VideoTake.takes(from: chatBridge.messages, isStreaming: chatBridge.isStreaming)
    }

    private var selectedTake: VideoTake? {
        let takes = takes
        if let take = takes.first(where: { $0.id == selectedID }) { return take }
        if !followsLatest, let ready = takes.last(where: { $0.phase == .ready }) { return ready }
        return takes.last
    }

    var body: some View {
        let takes = takes
        HStack(spacing: 0) {
            // The composer floats over the bottom of the stage; the clip is
            // inset by its height so the player controls stay reachable.
            ZStack(alignment: .bottom) {
                stage(for: takes)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                composer
                    .frame(maxWidth: 820)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { composerHeight = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !takes.isEmpty {
                Divider()
                VideoTakeList(
                    takes: takes,
                    selectedID: selectedTake?.id,
                    statuses: statuses,
                    activity: selectedTake?.toolCall.flatMap { activity[$0.id] } ?? [],
                    select: { id in selectedID = id }
                )
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoFileActions.fileDeleted)) { _ in
            fileRevision += 1
        }
        .animation(.smooth(duration: 0.3), value: takes.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: VideoGenerationProgress.notification)) { note in
            guard let callID = note.userInfo?[VideoGenerationProgress.callIDKey] as? String,
                  let status = note.userInfo?[VideoGenerationProgress.statusKey] as? String else { return }
            let actor = note.userInfo?[VideoGenerationProgress.actorKey] as? String
            statuses[callID] = actor.map { "\($0): \(status)" } ?? status
            var log = activity[callID, default: []]
            // Download and sampler updates can repeat; keep one line per change.
            guard log.last?.message != status || log.last?.actor != actor else { return }
            log.append(VideoGenerationActivity(message: status, actor: actor))
            activity[callID] = Array(log.suffix(200))
        }
        // A prompt sent in this thread takes over the stage so its render is
        // what the user sees. Loading another thread swaps the first take too,
        // so that keeps showing the thread's own finished clip.
        .onChange(of: takes.map(\.id)) { old, new in
            guard let first = old.first, first == new.first, new.count > old.count else { return }
            selectedID = nil
            followsLatest = true
        }
        .onChange(of: windowState.currentSessionId) { _, _ in
            selectedID = nil
            followsLatest = false
            statuses = [:]
            activity = [:]
        }
    }

    @ViewBuilder
    private func stage(for takes: [VideoTake]) -> some View {
        if let take = selectedTake {
            // No animated swap: an opacity transition interrupted by a sheet
            // or by the list sliding in as a thread loads can leave the stage
            // invisible.
            VideoStage(take: take, status: take.toolCall.flatMap { statuses[$0.id] }, bottomInset: composerHeight)
                .id(take.id)
                .transition(.identity)
        } else {
            VideoStudioEmptyStage()
                .padding(.bottom, composerHeight)
                .transition(.identity)
        }
    }
}

// MARK: - Stage

private struct VideoStage: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    let take: VideoTake
    let status: String?
    /// Space reserved at the bottom for the floating composer.
    let bottomInset: CGFloat

    @State private var player: AVPlayer?
    @State private var headerHeight: CGFloat = 0
    @State private var continueError: String?

    var body: some View {
        // A full-bleed black canvas: the details float over its top edge and
        // the composer over its bottom edge, with the clip fitted in between.
        // The black base always lays out, so the stage keeps its size and its
        // `.task` creates the player — an empty `screen` would collapse both.
        ZStack {
            Color.black
            screen
                .padding(.top, headerHeight)
                .padding(.bottom, bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            details
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .background {
                    LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = $0 }
        }
        .task(id: take.phase) {
            guard take.phase == .ready, let path = take.path else {
                player = nil
                return
            }
            player = AVPlayer(url: URL(fileURLWithPath: path))
        }
        .onChange(of: windowState.playingVideo?.path) { _, path in
            if path != nil { player?.pause() }
        }
        .onDisappear { player?.pause() }
        .alert("Couldn't Continue from Video", isPresented: Binding(
            get: { continueError != nil }, set: { if !$0 { continueError = nil } }
        )) {
            Button("OK", role: .cancel) { continueError = nil }
        } message: { Text(continueError ?? "") }
    }

    @ViewBuilder
    private var screen: some View {
        switch take.phase {
        case .ready:
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(take.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text("Generated video player", bundle: .module))
                    .modifier(VideoFileActions(path: take.path, beforePlayback: { player.pause() }, continues: true))
            }
        case .generating:
            VideoRenderingScreen(status: status, startedAt: take.date) {
                Task { await chatBridge.cancelStreaming() }
            }
        case .missing:
            ContentUnavailableView {
                Label { Text("Video Not Found", bundle: .module) } icon: { Image(systemName: "film") }
            } description: {
                Text("The video file is no longer on this device.", bundle: .module)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label { Text("Couldn't Generate Video", bundle: .module) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            } description: {
                Text(take.failureMessage)
                    .lineLimit(6)
                    .textSelection(.enabled)
            } actions: {
                Button {
                    windowState.inputText = take.prompt
                } label: {
                    Label { Text("Edit Prompt", bundle: .module) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(take.prompt.isEmpty || chatBridge.isStreaming)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(take.prompt.isEmpty ? String(localized: "Untitled prompt", bundle: .module) : take.prompt)
                    .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .textSelection(.enabled)
                    .help(take.prompt)
                if let meta = metaLine {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer(minLength: 8)

            if take.phase == .ready, let path = take.path {
                HStack(spacing: 4) {
                    Button {
                        Task {
                            do {
                                try await StudioContinuation.attachLastFrame(ofVideoAt: path, to: windowState)
                                if windowState.inputText.isEmpty { windowState.inputText = take.prompt }
                            } catch {
                                continueError = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help(String(localized: "Continue from this video's last frame", bundle: .module))

                    Button {
                        windowState.inputText = take.prompt
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help(String(localized: "Reuse prompt", bundle: .module))
                    .disabled(chatBridge.isStreaming)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help(String(localized: "Show in Finder", bundle: .module))

                    Button {
                        player?.pause()
                        windowState.playingVideo = PreviewFile(path: path, name: (path as NSString).lastPathComponent)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help(String(localized: "Open player", bundle: .module))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let width = take.width, let height = take.height { parts.append("\(width)×\(height)") }
        if let seconds = take.elapsedSeconds { parts.append(VideoStudioFormat.madeIn(seconds)) }
        if let model = take.model { parts.append(model) }
        if parts.isEmpty, take.phase == .generating {
            parts.append(chatBridge.modelDisplayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum VideoStudioFormat {
    static func madeIn(_ seconds: Int) -> String {
        seconds >= 60
            ? String(localized: "made in \(seconds / 60) min \(seconds % 60) s", bundle: .module)
            : String(localized: "made in \(seconds) s", bundle: .module)
    }
}

/// The live render: a moving light sweep, the sampler's status, a progress bar
/// (determinate once the sampler reports steps), elapsed time and Stop.
private struct VideoRenderingScreen: View {
    let status: String?
    let startedAt: Date
    let stop: () -> Void

    @State private var sweep = false

    private var fraction: Double? { VideoProgressStatus.fraction(in: status) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClaudeTheme.accent.opacity(0.0), ClaudeTheme.accent.opacity(0.22), ClaudeTheme.accent.opacity(0.0)],
                startPoint: sweep ? .topTrailing : .bottomLeading,
                endPoint: sweep ? .bottomLeading : .topTrailing
            )
            .blur(radius: 40)

            VStack(spacing: 18) {
                Image(systemName: "film.stack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 6) {
                    Text(status ?? String(localized: "Preparing…", bundle: .module))
                        .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                        .animation(.smooth, value: status)
                    Text(startedAt, style: .timer)
                        .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }

                Group {
                    if let fraction {
                        ProgressView(value: fraction)
                            .animation(.smooth, value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .tint(ClaudeTheme.accent)
                .frame(maxWidth: 320)

                Button(role: .destructive, action: stop) {
                    Label { Text("Stop", bundle: .module) } icon: { Image(systemName: "stop.fill") }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.white)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Generating video", bundle: .module))
    }
}

private struct VideoStudioEmptyStage: View {
    @Environment(ChatBridge.self) private var chatBridge

    var body: some View {
        ContentUnavailableView {
            Label { Text("Make a Video", bundle: .module) } icon: { Image(systemName: "film") }
        } description: {
            Text("Describe a scene below and \(chatBridge.modelDisplayName) renders a short clip with sound.", bundle: .module)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Generations list

private struct VideoTakeList: View {
    let takes: [VideoTake]
    let selectedID: UUID?
    let statuses: [String: String]
    /// The selected generation's activity log.
    let activity: [VideoGenerationActivity]
    let select: (UUID) -> Void

    @State private var showsActivity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Generations", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Text("\(takes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Button {
                    showsActivity.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Generation activity", bundle: .module))
                .accessibilityLabel(Text("Generation activity", bundle: .module))
                .popover(isPresented: $showsActivity, arrowEdge: .bottom) {
                    VideoActivityPopover(activity: activity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(takes.reversed()) { take in
                            VideoTakeRow(
                                take: take,
                                isSelected: take.id == selectedID,
                                status: take.toolCall.flatMap { statuses[$0.id] },
                                parentPrompt: parentPrompt(of: take)
                            )
                            .id(take.id)
                            .modifier(VideoFileActions(path: take.phase == .ready ? take.path : nil, select: { select(take.id) }, continues: true))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .onChange(of: takes.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
    }

    /// The prompt of the clip whose last frame started this one.
    private func parentPrompt(of take: VideoTake) -> String? {
        guard let source = take.sourcePath else { return nil }
        return takes.first { $0.path.map(StudioContinuation.lastFramePath(forVideoAt:)) == source }?.prompt
    }
}

/// The selected generation's steps, newest first: what RxCode did and what
/// the task model is doing while it looks up the companion files.
struct VideoActivityPopover: View {
    let activity: [VideoGenerationActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity", bundle: .module)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if activity.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Activity Yet", bundle: .module) } icon: { Image(systemName: "list.bullet.rectangle") }
                } description: {
                    Text("Steps appear here while a video is being prepared and rendered.", bundle: .module)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(activity.reversed()) { entry in
                            VideoActivityRow(entry: entry, isLatest: entry.id == activity.last?.id)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 360, height: 360)
    }
}

private struct VideoActivityRow: View {
    let entry: VideoGenerationActivity
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.actor == nil ? "gearshape" : "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(entry.actor == nil ? ClaudeTheme.textTertiary : ClaudeTheme.accent)
                .symbolEffect(.pulse, isActive: isLatest && entry.actor != nil)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message)
                    .font(.system(size: ClaudeTheme.size(12), weight: isLatest ? .medium : .regular))
                    .foregroundStyle(isLatest ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text([entry.actor, entry.date.formatted(.dateTime.hour().minute().second())]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VideoTakeRow: View {
    let take: VideoTake
    let isSelected: Bool
    let status: String?
    let parentPrompt: String?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VideoThumbnail(take: take)
                .frame(width: 80, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(take.prompt.isEmpty ? String(localized: "Untitled prompt", bundle: .module) : take.prompt)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let source = take.sourcePath {
                    StudioParentLine(path: source, prompt: parentPrompt)
                }
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? ClaudeTheme.sidebarItemSelected : (isHovered ? ClaudeTheme.sidebarItemHover : .clear),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch take.phase {
        case .generating:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = VideoProgressStatus.fraction(in: status) {
                    ProgressView(value: fraction).controlSize(.mini)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini)
                }
                Text(status ?? String(localized: "Preparing…", bundle: .module))
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .tint(ClaudeTheme.accent)
        case .ready:
            Text([take.date.formatted(.dateTime.hour().minute()), take.elapsedSeconds.map(VideoStudioFormat.madeIn)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.textTertiary)
        case .missing:
            Text("File missing", bundle: .module)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusWarning)
        case .failed:
            Text("Failed", bundle: .module)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusError)
        }
    }
}

/// First frame of a finished clip, or a phase glyph.
private struct VideoThumbnail: View {
    let take: VideoTake
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(take.phase == .failed ? ClaudeTheme.statusError : .white.opacity(0.7))
                    .symbolEffect(.pulse, isActive: take.phase == .generating)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
        }
        .task(id: take.phase == .ready ? take.path : nil) {
            guard take.phase == .ready, let path = take.path else { image = nil; return }
            image = await Self.firstFrame(of: URL(fileURLWithPath: path))
        }
    }

    private var glyph: String {
        switch take.phase {
        case .generating: "film.stack"
        case .ready: "play.fill"
        case .missing: "questionmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func firstFrame(of url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif
