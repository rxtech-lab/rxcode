import RxCodeCore
import SwiftUI

struct DesignSelection: Identifiable {
    let id = UUID()
    let title: String
    let context: String
    var image: NSImage?
    var point: CGPoint
    var rect: CGRect?

    mutating func markImage(in displayedSize: CGSize) {
        guard let original = image, displayedSize.width > 0, displayedSize.height > 0 else { return }
        let size = original.size
        let sx = size.width / displayedSize.width, sy = size.height / displayedSize.height
        let marker = rect.map { CGRect(x: $0.minX*sx, y: $0.minY*sy, width: $0.width*sx, height: $0.height*sy) }
        let center = CGPoint(x: point.x*sx, y: point.y*sy)
        let width = max(2, size.width / 300)
        image = NSImage(size: size, flipped: true) { canvas in
            original.draw(in: canvas, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            let path = marker.map { NSBezierPath(roundedRect: $0, xRadius: width, yRadius: width) }
                ?? NSBezierPath(ovalIn: CGRect(x: center.x - 4*width, y: center.y - 4*width, width: 8*width, height: 8*width))
            NSColor.white.setStroke(); path.lineWidth = width * 2; path.stroke()
            NSColor.systemOrange.setStroke(); path.lineWidth = width; path.stroke()
            return true
        }
    }
}

/// Coordinates are local to the visible page or to the fitted screenshot.
struct DesignSelectionOverlay: View {
    let boundsAtPoint: ((CGPoint, CGSize) async -> CGRect?)?
    let select: (CGPoint, CGSize) async throws -> DesignSelection
    @Environment(AppState.self) private var app
    @Environment(WindowState.self) private var window
    @State private var selection: DesignSelection?
    @State private var error: String?
    @State private var request = UUID()
    @State private var hoverPoint: CGPoint?
    @State private var hoverRect: CGRect?
    @State private var hoverTask: Task<Void, Never>?

    init(boundsAtPoint: ((CGPoint, CGSize) async -> CGRect?)? = nil,
         select: @escaping (CGPoint, CGSize) async throws -> DesignSelection) {
        self.boundsAtPoint = boundsAtPoint
        self.select = select
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        let id = UUID()
                        request = id
                        Task {
                            do {
                                var picked = try await select(point, geometry.size)
                                guard request == id else { return }
                                picked.markImage(in: geometry.size)
                                clearHover()
                                selection = picked
                            } catch { if request == id { self.error = error.localizedDescription } }
                        }
                    }
                    .pointerStyle(.rectSelection)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): trackHover(at: point, size: geometry.size)
                        case .ended: clearHover()
                        @unknown default: break
                        }
                    }
                if let selection {
                    if let rect = selection.rect {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: max(2, rect.width), height: max(2, rect.height))
                            .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                    } else {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 18, height: 18)
                            .position(selection.point).allowsHitTesting(false)
                    }
                    Color.clear.frame(width: 2, height: 2)
                        .popover(isPresented: Binding(get: { self.selection != nil }, set: { if !$0 { self.selection = nil } })) {
                            RefinementPopover(title: selection.title, preview: selection.image) { prompt in
                                self.selection = nil
                                Task {
                                    await app.submitRefinement(prompt, context: "Selected interface element\n\(selection.context)",
                                                               image: selection.image, in: window)
                                }
                            }
                            .id(selection.id)
                        }
                        .position(selection.point)
                } else if let hoverRect {
                    Rectangle()
                        .fill(ClaudeTheme.accent.opacity(0.12))
                        .overlay { Rectangle().strokeBorder(.white, lineWidth: 3) }
                        .overlay { Rectangle().strokeBorder(ClaudeTheme.accent, lineWidth: 2) }
                        .frame(width: hoverRect.width, height: hoverRect.height)
                        .position(x: hoverRect.midX, y: hoverRect.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .onChange(of: geometry.size) { clearHover() }
        }
        .onDisappear {
            request = UUID()
            clearHover()
        }
        .alert("Couldn’t select this element", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func trackHover(at point: CGPoint, size: CGSize) {
        guard let boundsAtPoint, selection == nil else { return }
        hoverPoint = point
        guard hoverTask == nil else { return }

        // Keep one lookup in flight and use the latest point for the next one.
        hoverTask = Task {
            while let point = hoverPoint {
                let bounds = await boundsAtPoint(point, size)
                guard !Task.isCancelled else { return }
                hoverRect = bounds
                if point == hoverPoint { break }
            }
            hoverTask = nil
        }
    }

    private func clearHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverPoint = nil
        hoverRect = nil
    }
}

struct RefinementPopover: View {
    let title: String
    var isComment = false
    var excerpt: String?
    var preview: NSImage?
    var previewCaption: String?
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: isComment ? "text.bubble" : "scope").font(.headline).lineLimit(2)
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .accessibilityLabel("Preview attached to the comment")
            }
            if let previewCaption { Text(previewCaption).font(.caption).foregroundStyle(.secondary) }
            if let excerpt {
                Text(verbatim: String(excerpt.prefix(240)))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier("comment-excerpt")
            }
            TextField(isComment ? "Add a comment" : "Describe the refinement", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6).focused($focused)
            HStack {
                Spacer()
                Button("Send to Chat") { send(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14).frame(width: 310)
        .onAppear { focused = true }
    }
}

extension AppState {
    func submitRefinement(_ instruction: String, context: String, image: NSImage? = nil,
                          imageName: String = "Design selection.png", in window: WindowState) async {
        if window.selectedProject == nil { openGlobalChat(in: window) }
        window.generalRoute = window.selectedProject?.isGlobalChat == true ? .chat : nil
        let prompt = "\(instruction)\n\n\(context)"
        let attachments: [Attachment]
        if let image, let data = designPNG(image) {
            attachments = [.init(type: .image, name: imageName, fileSize: Int64(data.count), imageData: data)]
        } else { attachments = [] }
        if isStreaming(in: window) {
            enqueueMessage(text: prompt, attachments: attachments, in: window)
        } else {
            let (resolved, paths) = AttachmentFactory.resolvingClipboardImages(attachments)
            let fullPrompt = buildPromptWithAttachments(prompt, attachments: resolved)
            _ = await sendPrompt(fullPrompt, displayText: prompt, attachments: resolved, tempFilePaths: paths,
                                 useProjectEffortForNewChat: true, in: window)
        }
    }
}

func designPNG(_ image: NSImage) -> Data? {
    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
}
