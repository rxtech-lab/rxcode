import AppKit
import RxCodeChatKit
import RxCodeCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The description field for tasks and stories: a Markdown source editor with a
/// preview toggle that accepts pasted and dropped images, files and text.
///
/// Dropped and pasted content is written into the description as Markdown —
/// `![name](file://…)` for an image, `[name](file://…)` for anything else — so
/// `details` stays a plain Markdown string that `agentPrompt` can carry verbatim.
/// When `attachments` is bound (tasks; stories have no attachment list) the same
/// file is also registered as an attachment, which is what actually ships to the
/// agent on dispatch.
///
/// The source editor is the chat input's `IMETextView`, so an image reference
/// shows as the same `[ImageN]` chip the chat composer uses. The field edits a
/// display string in which each `![name](url)` is stood in for by its token;
/// `DescriptionImageChips` maps between that and the stored Markdown.
struct MarkdownDescriptionEditor: View {
    @Binding var text: String
    var attachments: Binding<[Attachment.DTO]>?
    var placeholder: String
    var isDisabled: Bool = false
    var height: CGFloat = 170

    @State private var controller = MarkdownEditorController()
    @State private var isDropTargeted = false
    @State private var showsPreview = false
    @State private var chips = DescriptionImageChips()
    @State private var displayText = ""
    @State private var isFocused = false
    @State private var hasMarkedText = false
    @State private var previewImage: Attachment?

    /// Drops are accepted in preview mode too — the caret is unavailable there,
    /// so `insert` falls back to appending.
    private var acceptsContent: Bool { !isDisabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(height: height)
                .background(ClaudeTheme.inputBackground, in: shape)
                .overlay {
                    shape.strokeBorder(
                        isDropTargeted ? ClaudeTheme.accent : ClaudeTheme.inputBorder,
                        lineWidth: isDropTargeted ? 1.5 : 1
                    )
                }
                .onDrop(of: AttachmentIntake.dropTypes, isTargeted: $isDropTargeted) { providers in
                    guard acceptsContent else { return false }
                    handleDrop(providers)
                    return true
                }
                .overlay { dropHint }
            if !isDisabled {
                Text("Markdown. Paste or drop images and files to attach them.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .sheet(item: $previewImage) { ImagePreviewSheet(attachment: $0) }
        .onAppear {
            displayText = chips.display(for: text)
            controller.fallbackAppend = { [binding = $displayText] snippet in
                let current = binding.wrappedValue
                binding.wrappedValue = current.isEmpty || current.hasSuffix("\n")
                    ? current + snippet
                    : current + "\n" + snippet
            }
        }
        .onChange(of: text) { _, newValue in
            // Only an outside change (e.g. a reset) re-derives the chips; our own
            // write-back already matches the display string.
            guard chips.markdown(for: displayText) != newValue else { return }
            displayText = chips.display(for: newValue)
        }
        .onChange(of: displayText) { _, newValue in
            let markdown = chips.markdown(for: newValue)
            if markdown != text { text = markdown }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Description")
            Spacer()
            Picker("Editor Mode", selection: $showsPreview) {
                Image(systemName: "pencil").tag(false)
                Image(systemName: "eye").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the Markdown source and its preview")
            .accessibilityIdentifier("task-description-mode")
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsPreview {
            ScrollView {
                Group {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .foregroundStyle(ClaudeTheme.inputPlaceholder)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownContentView(text: text)
                    }
                }
                .padding(8)
            }
        } else {
            IMETextView(
                text: $displayText,
                isFocused: $isFocused,
                hasMarkedText: $hasMarkedText,
                font: .monospacedSystemFont(ofSize: ClaudeTheme.size(12), weight: .regular),
                textColor: NSColor(isDisabled ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary),
                placeholder: placeholder,
                onReturn: { [controller] in controller.insert("\n") },
                onPasteCommandV: handlePaste,
                onImageChipTap: openImage,
                isEditable: !isDisabled,
                accessibilityIdentifier: "task-description-editor",
                onTextViewReady: { [controller] textView in
                    // NSTextView would swallow a dropped file into a path string;
                    // unregistering lets the drag reach the SwiftUI drop target.
                    textView.unregisterDraggedTypes()
                    controller.textView = textView
                },
                chipThumbnail: { index in
                    chips.url(forChip: index).flatMap(ChipThumbnailCache.shared.thumbnail(for:))
                }
            )
            .padding(6)
        }
    }

    @ViewBuilder
    private var dropHint: some View {
        if isDropTargeted, acceptsContent {
            shape
                .fill(ClaudeTheme.accent.opacity(0.08))
                .overlay {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: - Paste & Drop

    /// Returns `true` when the paste was consumed here; `false` lets the text
    /// view run its own plain-text paste, which keeps undo and IME intact.
    private func handlePaste() -> Bool {
        guard acceptsContent else { return true }
        guard let pasted = AttachmentIntake.attachments(from: .general) else { return false }
        pasted.forEach(attach)
        return true
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        AttachmentIntake.load(
            providers,
            onAttachment: attach,
            onText: { [controller] text in controller.insert(text) }
        )
    }

    // MARK: - Attaching

    private func attach(_ attachment: Attachment) {
        // A pasted image exists only in memory; writing it out gives the
        // Markdown link a path that still resolves after a relaunch.
        let resolved = AttachmentFactory.resolvingClipboardImages([attachment]).resolved
        for item in resolved {
            let reference = Self.markdownReference(for: item)
            controller.insertBlock(item.type == .image ? chips.token(for: reference) : reference)
            guard let attachments, !item.path.isEmpty else { continue }
            let dto = item.persistableInTaskBoard().dto
            guard !attachments.wrappedValue.contains(where: { $0.path == dto.path }) else { continue }
            attachments.wrappedValue.append(dto)
        }
    }

    private func openImage(_ index: Int) {
        guard let url = chips.url(forChip: index) else { return }
        previewImage = Attachment(type: .image, name: url.lastPathComponent, path: url.path)
    }

    /// `![alt](file://…)` for an image, `[label](file://…)` otherwise. The URL
    /// form is used rather than a bare path because Markdown link destinations
    /// end at the first space, and paths routinely contain spaces.
    static func markdownReference(for attachment: Attachment) -> String {
        let label = attachment.name
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = attachment.path.isEmpty
            ? attachment.name
            : URL(fileURLWithPath: attachment.path).absoluteString
        return "\(attachment.type == .image ? "!" : "")[\(label)](\(destination))"
    }
}

// MARK: - Image chips

/// Maps a description's Markdown to the chat input's chip form and back: each
/// image reference becomes `[ImageN]`, where N is its 1-based slot in
/// `references`. Slots are only ever appended, so a token keeps pointing at the
/// same image while the user edits around it.
struct DescriptionImageChips {
    private(set) var references: [String] = []

    private static let imageReference = try! NSRegularExpression(
        pattern: #"!\[(?:\\.|[^\]\\\n])*\]\([^)\s]+\)"#
    )
    private static let chipToken = try! NSRegularExpression(pattern: #"\[Image(\d+)\]"#)

    /// The `[ImageN]` token for a reference, registering it if it is new.
    mutating func token(for reference: String) -> String {
        if let index = references.firstIndex(of: reference) {
            return "[Image\(index + 1)]"
        }
        references.append(reference)
        return "[Image\(references.count)]"
    }

    mutating func display(for markdown: String) -> String {
        let ns = markdown as NSString
        let matches = Self.imageReference.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += token(for: ns.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }

    /// Tokens with no registered reference are left as typed.
    func markdown(for display: String) -> String {
        let ns = display as NSString
        let matches = Self.chipToken.matches(in: display, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range)
            if let slot = Int(ns.substring(with: match.range(at: 1))), references.indices.contains(slot - 1) {
                result += references[slot - 1]
            } else {
                result += token
            }
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }

    /// The file an `[ImageN]` chip points at, when it is a local file.
    func url(forChip index: Int) -> URL? {
        guard references.indices.contains(index - 1) else { return nil }
        let reference = references[index - 1]
        guard let open = reference.lastIndex(of: "("),
              let url = URL(string: String(reference[reference.index(after: open)...].dropLast())),
              url.isFileURL
        else { return nil }
        return url
    }
}

// MARK: - Chip thumbnails

/// Small downsampled copies of chip images. Glyph generation asks for them on
/// every layout pass, so each file is decoded once — misses included.
@MainActor
final class ChipThumbnailCache {
    static let shared = ChipThumbnailCache()

    private var thumbnails: [String: NSImage?] = [:]

    func thumbnail(for url: URL) -> NSImage? {
        cached(url.path) { CGImageSourceCreateWithURL(url as CFURL, nil) }
    }

    /// A pasted image may exist only in memory, so its data is used when it
    /// has no file.
    func thumbnail(for attachment: Attachment) -> NSImage? {
        if !attachment.path.isEmpty { return thumbnail(for: URL(fileURLWithPath: attachment.path)) }
        guard let data = attachment.imageData else { return nil }
        return cached(attachment.id.uuidString) { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    private func cached(_ key: String, source: () -> CGImageSource?) -> NSImage? {
        if let cached = thumbnails[key] { return cached }
        let image = source().flatMap(Self.makeThumbnail(from:))
        thumbnails[key] = image
        return image
    }

    private static func makeThumbnail(from source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: - Controller

/// Routes programmatic insertions through the live text view so they land at
/// the caret and join its undo stack. Held by `@State` so the drop callbacks,
/// which capture a snapshot of the view, still reach the current text view.
@MainActor
final class MarkdownEditorController {
    weak var textView: NSTextView?
    /// Applied when no text view is mounted — the preview tab is showing.
    var fallbackAppend: ((String) -> Void)?

    func insert(_ snippet: String) {
        guard let textView, textView.isEditable else {
            fallbackAppend?(snippet)
            return
        }
        textView.insertText(snippet, replacementRange: textView.selectedRange())
    }

    /// Inserts a snippet on a line of its own, adding only the newlines that
    /// are actually missing around the caret.
    func insertBlock(_ snippet: String) {
        guard let textView, textView.isEditable else {
            fallbackAppend?("\n" + snippet + "\n")
            return
        }
        let range = textView.selectedRange()
        let string = textView.string as NSString
        var padded = snippet
        if range.location > 0, string.character(at: range.location - 1) != 0x0A {
            padded = "\n" + padded
        }
        let end = min(NSMaxRange(range), string.length)
        if end == string.length || string.character(at: end) != 0x0A {
            padded += "\n"
        }
        textView.insertText(padded, replacementRange: range)
    }
}
