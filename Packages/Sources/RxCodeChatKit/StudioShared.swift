import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One prompt in a studio thread and what the studio's tool made for it,
/// read back from the thread's messages: each user message is a prompt, and
/// the assistant's tool call that follows carries the result.
struct GenerationTake: Identifiable, Equatable {
    enum Phase: Equatable { case generating, ready, missing, failed }

    let id: UUID
    let prompt: String
    let date: Date
    let toolCall: ToolCall?
    /// Files the user attached to the prompt (a source image or audio).
    let attachments: [AttachmentInfo]
    /// Text the model replied with instead of a result, e.g. for an empty prompt.
    let reply: String?
    let phase: Phase

    var output: [String: JSONValue] { Self.decode(toolCall?.result) }

    var path: String? { output["savedPath"]?.stringValue }
    func string(_ key: String) -> String? { output[key]?.stringValue }
    func int(_ key: String) -> Int? { output[key]?.numberValue.map(Int.init) }
    func double(_ key: String) -> Double? { output[key]?.numberValue }

    var failureMessage: String {
        if let message = output["displayError"]?.stringValue { return message }
        if let reply, !reply.isEmpty { return reply }
        return toolCall == nil
            ? String(localized: "Nothing was generated", bundle: .module)
            : String(localized: "Generation was stopped", bundle: .module)
    }

    /// The image this take continued from: the source the tool recorded, else
    /// the image attached to the prompt. With `inheritsLatest`, a running take
    /// without an attachment continues from the newest image before it, as
    /// the image studio's harness does.
    func parentPath(in takes: [GenerationTake], inheritsLatest: Bool = false) -> String? {
        if let source = string("sourcePath") { return source }
        if let attached = attachments.first(where: \.isImage) { return attached.path }
        guard inheritsLatest, phase == .generating, let index = takes.firstIndex(where: { $0.id == id }) else { return nil }
        return takes[..<index].last { $0.phase == .ready }?.path
    }

    static func decode(_ result: String?) -> [String: JSONValue] {
        guard let result, let data = result.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    /// With `requiresFile`, a finished take whose `savedPath` is gone from
    /// disk is `.missing`.
    static func takes(from messages: [ChatMessage], toolName: String, isStreaming: Bool, requiresFile: Bool = true) -> [GenerationTake] {
        var takes: [GenerationTake] = []
        let lastUser = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() where message.role == .user && !message.isCompactBoundary {
            // The assistant rows that answer this prompt, up to the next prompt.
            let replies = messages[(index + 1)...].prefix { $0.role != .user }
            let call = replies.lazy.flatMap(\.toolCalls).last { $0.name.lowercased() == toolName.lowercased() }
            let reply = replies.map(\.content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let phase: Phase
            if let call, call.result != nil {
                let path = decode(call.result)["savedPath"]?.stringValue
                if call.isError || decode(call.result)["displayError"] != nil {
                    phase = .failed
                } else if requiresFile {
                    phase = path.map { FileManager.default.fileExists(atPath: $0) } == true ? .ready : (path == nil ? .failed : .missing)
                } else {
                    phase = .ready
                }
            } else if index == lastUser && isStreaming {
                phase = .generating
            } else {
                phase = .failed
            }
            takes.append(GenerationTake(
                id: message.id, prompt: message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                date: message.timestamp, toolCall: call, attachments: message.attachmentPaths,
                reply: reply.isEmpty ? nil : reply, phase: phase
            ))
        }
        return takes
    }
}

/// Branching: puts a finished generation in the composer as the parent of the
/// next prompt, replacing any other attached image.
@MainActor
enum StudioContinuation {
    static func attachImage(at path: String, to windowState: WindowState) {
        let url = URL(fileURLWithPath: path)
        let data = try? Data(contentsOf: url)
        windowState.attachments.removeAll { $0.type == .image }
        windowState.attachments.append(Attachment(
            type: .image, name: url.lastPathComponent, path: path,
            fileSize: data.map { Int64($0.count) }, imageData: data
        ))
    }

    /// A clip continues from its last frame, saved beside it as a PNG.
    static func attachLastFrame(ofVideoAt path: String, to windowState: WindowState) async throws {
        let frame = try await lastFrame(ofVideoAt: URL(fileURLWithPath: path))
        attachImage(at: frame.path, to: windowState)
    }

    nonisolated static func lastFramePath(forVideoAt path: String) -> String {
        ((path as NSString).deletingPathExtension) + "-last-frame.png"
    }

    nonisolated static func lastFrame(ofVideoAt url: URL) async throws -> URL {
        let output = URL(fileURLWithPath: lastFramePath(forVideoAt: url.path))
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The exact end has no frame; step back a frame's worth.
        let time = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        let (image, _) = try await generator.image(at: CMTimeMaximum(time, .zero))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}

/// A list row's "from …" line: the parent's thumbnail and its prompt.
struct StudioParentLine: View {
    let path: String
    /// The parent's prompt, when the parent is a take in this thread.
    let prompt: String?

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.85))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(prompt.map { String(localized: "from \($0)", bundle: .module) } ?? String(localized: "from an image", bundle: .module))
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(String(localized: "Continued from this image", bundle: .module))
        .task(id: path) { thumbnail = await StudioThumbnail.image(path, maxPixelSize: 48) }
    }
}

/// Composer card for the image the next prompt continues from when nothing
/// is attached: the thread's newest image.
struct StudioImplicitParentCard: View {
    let path: String
    let open: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            ClaudeTheme.surfaceSecondary
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 104)
                    .clipped()
            }
            Label { Text("Continues from", bundle: .module) } icon: { Image(systemName: "arrow.triangle.branch") }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.5))
        }
        .frame(width: 96, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeTheme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: open)
        .help(String(localized: "Your next prompt continues from the newest image. To branch, right-click another image and choose Continue from This Image.", bundle: .module))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: path) { thumbnail = await StudioThumbnail.image(path, maxPixelSize: 220) }
    }
}

enum StudioThumbnail {
    /// Decoded off the main thread.
    static func image(_ path: String, maxPixelSize: Int) async -> NSImage? {
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        }.value
        return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

/// Which take a studio shows: the one the user picked, else — once a prompt
/// was sent in the open thread — the newest take, else the thread's latest
/// finished result.
struct StudioSelection: Equatable {
    var selectedID: UUID?
    var followsLatest = false

    func take(in takes: [GenerationTake]) -> GenerationTake? {
        if let take = takes.first(where: { $0.id == selectedID }) { return take }
        if !followsLatest, let ready = takes.last(where: { $0.phase == .ready }) { return ready }
        return takes.last
    }

    /// A prompt sent in this thread takes over. Loading another thread swaps
    /// the first take too, which keeps showing that thread's own result.
    mutating func takesChanged(from old: [UUID], to new: [UUID]) {
        guard let first = old.first, first == new.first, new.count > old.count else { return }
        selectedID = nil
        followsLatest = true
    }
}

/// Collects the studio tools' progress notifications: the latest status per
/// tool call and every status it posted, for the activity popover.
struct StudioProgressTracker: ViewModifier {
    @Binding var statuses: [String: String]
    @Binding var activity: [String: [VideoGenerationActivity]]

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: VideoGenerationProgress.notification)) { note in
            guard let callID = note.userInfo?[VideoGenerationProgress.callIDKey] as? String,
                  let status = note.userInfo?[VideoGenerationProgress.statusKey] as? String else { return }
            let actor = note.userInfo?[VideoGenerationProgress.actorKey] as? String
            statuses[callID] = actor.map { "\($0): \(status)" } ?? status
            var log = activity[callID, default: []]
            guard log.last?.message != status || log.last?.actor != actor else { return }
            log.append(VideoGenerationActivity(message: status, actor: actor))
            activity[callID] = Array(log.suffix(200))
        }
    }
}

extension View {
    func studioProgress(statuses: Binding<[String: String]>, activity: Binding<[String: [VideoGenerationActivity]]>) -> some View {
        modifier(StudioProgressTracker(statuses: statuses, activity: activity))
    }
}

/// Opens the studio's Engine & Setup Agent sheet. The choices apply to the
/// studio's future generations and are remembered per studio.
struct StudioSetupButton: View {
    @Environment(WindowState.self) private var windowState
    let kind: LocalStudioKind

    var body: some View {
        Button {
            windowState.studioSettingsKind = kind
        } label: {
            Image(systemName: "gearshape.2")
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Engine and setup agent for this studio", bundle: .module))
        .accessibilityLabel(Text("Engine and setup agent", bundle: .module))
        .accessibilityIdentifier("studio-setup-button")
    }
}

/// The live job: a moving light sweep, the tool's status, a progress bar
/// (determinate once the engine reports steps), elapsed time and Stop.
struct StudioWorkingScreen: View {
    let systemImage: String
    let status: String?
    let startedAt: Date
    var tint: Color = .white
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
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(tint.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 6) {
                    Text(status ?? String(localized: "Preparing…", bundle: .module))
                        .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .animation(.smooth, value: status)
                    Text(startedAt, style: .timer)
                        .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                        .foregroundStyle(tint.opacity(0.6))
                }

                Group {
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                            .foregroundStyle(tint)
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
                .tint(tint)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The right-hand list of a studio's takes, newest first, with the
/// selected take's activity behind the info button.
struct StudioTakeList<Row: View>: View {
    let title: String
    let takes: [GenerationTake]
    /// The selected take's activity log.
    let activity: [VideoGenerationActivity]
    let select: (UUID) -> Void
    var open: ((GenerationTake) -> Void)? = nil
    /// Branching: makes a finished take the parent of the next prompt.
    var continueFrom: ((GenerationTake) -> Void)? = nil
    @ViewBuilder let row: (GenerationTake) -> Row

    @State private var showsActivity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: title)
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
                            row(take)
                                .id(take.id)
                                .onTapGesture(count: 2) {
                                    select(take.id)
                                    open?(take)
                                }
                                .onTapGesture { select(take.id) }
                                .modifier(StudioGenerationActions(take: take, continueFrom: continueFrom.map { action in { action(take) } }))
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
}

/// A list row's frame: selection and hover background around its content.
struct StudioRowBackground: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
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
}

/// The status line under a take's prompt in a studio list.
struct StudioTakeStatus: View {
    let take: GenerationTake
    let status: String?
    /// Shown for a finished take, after its time.
    let detail: String?

    var body: some View {
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
            Text([take.date.formatted(.dateTime.hour().minute()), detail].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
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

/// An icon button in a studio's floating details bar.
struct StudioActionButton: View {
    let systemImage: String
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(Text(help))
        .disabled(isDisabled)
    }
}
#endif
