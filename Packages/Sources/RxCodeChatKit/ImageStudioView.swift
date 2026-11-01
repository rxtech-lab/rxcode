import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit
import ImageIO

/// The chat surface for a local image model: a large canvas for the selected
/// image (or the live render) and a list of every image in the thread beside
/// it. Replaces the message list while an image model is selected.
///
/// Refine attaches the shown image to the composer; the next prompt then
/// reworks it instead of starting from noise.
struct ImageStudioView<Composer: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    private let composer: Composer

    @State private var selection = StudioSelection()
    @State private var statuses: [String: String] = [:]
    @State private var activity: [String: [VideoGenerationActivity]] = [:]
    @State private var composerHeight: CGFloat = 0
    @State private var preview: Attachment?

    init(@ViewBuilder composer: () -> Composer) {
        self.composer = composer()
    }

    private var takes: [GenerationTake] {
        GenerationTake.takes(from: chatBridge.messages, toolName: LocalStudioKind.image.toolName ?? "", isStreaming: chatBridge.isStreaming)
    }

    var body: some View {
        let takes = takes
        let selected = selection.take(in: takes)
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if let take = selected {
                        // No animated swap: an opacity transition interrupted
                        // by a sheet (double-click preview) or by the list
                        // sliding in as a thread loads can leave the canvas
                        // invisible.
                        ImageCanvas(take: take, status: take.toolCall.flatMap { statuses[$0.id] }, bottomInset: composerHeight)
                            .modifier(StudioGenerationActions(take: take, continueFrom: { continueFrom(take) }))
                            .id(take.id)
                            .transition(.identity)
                    } else {
                        ContentUnavailableView {
                            Label { Text("Make an Image", bundle: .module) } icon: { Image(systemName: "photo") }
                        } description: {
                            Text("Describe a picture below and \(chatBridge.modelDisplayName) paints it. Attach an image to refine it.", bundle: .module)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, composerHeight)
                        .transition(.identity)
                    }
                }
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
                StudioTakeList(
                    title: String(localized: "Images", bundle: .module),
                    takes: takes,
                    activity: selected?.toolCall.flatMap { activity[$0.id] } ?? [],
                    select: { id in selection.selectedID = id },
                    open: { take in
                        guard take.phase == .ready, let path = take.path else { return }
                        preview = Attachment(type: .image, name: URL(fileURLWithPath: path).lastPathComponent, path: path)
                    },
                    continueFrom: continueFrom
                ) { take in
                    ImageTakeRow(take: take, status: take.toolCall.flatMap { statuses[$0.id] }, parent: parent(of: take, in: takes))
                        .modifier(StudioRowBackground(isSelected: take.id == selected?.id))
                }
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: takes.isEmpty)
        .sheet(item: $preview) { ImagePreviewSheet(attachment: $0) }
        .studioProgress(statuses: $statuses, activity: $activity)
        .onChange(of: takes.map(\.id)) { old, new in selection.takesChanged(from: old, to: new) }
        .onChange(of: windowState.currentSessionId) { _, _ in
            selection = StudioSelection()
            statuses = [:]
            activity = [:]
        }
    }

    /// Selects the take and makes it the parent of the next prompt.
    private func continueFrom(_ take: GenerationTake) {
        guard take.phase == .ready, let path = take.path else { return }
        selection.selectedID = take.id
        StudioContinuation.attachImage(at: path, to: windowState)
    }

    private func parent(of take: GenerationTake, in takes: [GenerationTake]) -> (path: String, prompt: String?)? {
        guard let path = take.parentPath(in: takes, inheritsLatest: true) else { return nil }
        return (path, takes.first { $0.path == path }?.prompt)
    }
}

// MARK: - Canvas

private struct ImageCanvas: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    let take: GenerationTake
    let status: String?
    let bottomInset: CGFloat

    @State private var image: NSImage?
    @State private var headerHeight: CGFloat = 0
    @State private var copied = false
    @State private var preview: Attachment?

    var body: some View {
        // The black base always lays out, so the canvas fills the studio and
        // its `.task` runs even before the image has loaded — modifiers on an
        // empty `screen` would collapse the whole canvas and never load it.
        ZStack {
            Color.black
            screen
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
        .sheet(item: $preview) { ImagePreviewSheet(attachment: $0) }
        .animation(.smooth(duration: 0.2), value: copied)
        .task(id: take.path) {
            guard take.phase == .ready, let path = take.path else { image = nil; return }
            image = NSImage(contentsOfFile: path)
        }
    }

    /// A finished image fills the whole canvas, under the floating header
    /// and composer; the other screens sit between them so their text and
    /// buttons stay reachable.
    @ViewBuilder
    private var screen: some View {
        if take.phase == .ready {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { open() }
                    .accessibilityLabel(Text("Generated image", bundle: .module))
            }
        } else {
            phaseScreen
                .padding(.top, headerHeight)
                .padding(.bottom, bottomInset)
        }
    }

    @ViewBuilder
    private var phaseScreen: some View {
        switch take.phase {
        case .ready:
            EmptyView()
        case .generating:
            StudioWorkingScreen(systemImage: take.attachments.contains(where: \.isImage) ? "wand.and.stars" : "photo",
                                status: status, startedAt: take.date) {
                Task { await chatBridge.cancelStreaming() }
            }
        case .missing:
            ContentUnavailableView {
                Label { Text("Image Not Found", bundle: .module) } icon: { Image(systemName: "photo") }
            } description: {
                Text("The image file is no longer on this device.", bundle: .module)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label { Text("Couldn't Generate Image", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
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
            if let source = take.string("sourcePath"), let thumbnail = NSImage(contentsOfFile: source) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.4), lineWidth: 0.5) }
                    .help(String(localized: "Refined from this image", bundle: .module))
            }
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
                    StudioActionButton(systemImage: "arrow.triangle.branch", help: String(localized: "Continue from this image", bundle: .module)) { refine(path) }
                    StudioActionButton(systemImage: "text.badge.plus", help: String(localized: "Reuse prompt", bundle: .module),
                                       isDisabled: chatBridge.isStreaming) { windowState.inputText = take.prompt }
                    StudioActionButton(systemImage: "doc.on.doc", help: String(localized: "Copy image", bundle: .module)) { copy() }
                    StudioActionButton(systemImage: "folder", help: String(localized: "Show in Finder", bundle: .module)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    StudioActionButton(systemImage: "arrow.up.left.and.arrow.down.right", help: String(localized: "Preview image", bundle: .module)) { open() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let width = take.int("width"), let height = take.int("height") { parts.append("\(width)×\(height)") }
        if let steps = take.int("steps") { parts.append(String(localized: "\(steps) steps", bundle: .module)) }
        if let seed = take.int("seed") { parts.append(String(localized: "seed \(seed)", bundle: .module)) }
        if let seconds = take.int("elapsedSeconds") { parts.append(VideoStudioFormat.madeIn(seconds)) }
        if let model = take.string("model") { parts.append(model) }
        if parts.isEmpty, take.phase == .generating { parts.append(chatBridge.modelDisplayName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Puts the image in the composer as the refine source, replacing any
    /// other attached image, and keeps the prompt for editing.
    private func refine(_ path: String) {
        StudioContinuation.attachImage(at: path, to: windowState)
        if windowState.inputText.isEmpty { windowState.inputText = take.prompt }
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func open() {
        guard let path = take.path else { return }
        preview = Attachment(type: .image, name: URL(fileURLWithPath: path).lastPathComponent, path: path)
    }
}

// MARK: - List

private struct ImageTakeRow: View {
    let take: GenerationTake
    let status: String?
    let parent: (path: String, prompt: String?)?

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(take.phase == .failed ? ClaudeTheme.statusError : .white.opacity(0.7))
                        .symbolEffect(.pulse, isActive: take.phase == .generating)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5) }
            .task(id: take.phase == .ready ? take.path : nil) {
                guard take.phase == .ready, let path = take.path else { thumbnail = nil; return }
                thumbnail = await StudioThumbnail.image(path, maxPixelSize: 160)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(take.prompt.isEmpty ? String(localized: "Untitled prompt", bundle: .module) : take.prompt)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let parent {
                    StudioParentLine(path: parent.path, prompt: parent.prompt)
                }
                StudioTakeStatus(take: take, status: status, detail: take.int("elapsedSeconds").map(VideoStudioFormat.madeIn))
            }
            Spacer(minLength: 0)
        }
    }

    private var glyph: String {
        switch take.phase {
        case .generating: "photo"
        case .ready: "photo.fill"
        case .missing: "questionmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
#endif
