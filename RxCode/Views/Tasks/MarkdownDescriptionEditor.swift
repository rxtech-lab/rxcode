import AppKit
import RxCodeChatKit
import RxCodeCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A Markdown field shared by task descriptions and plan-mode requests and messages.
///
/// Dropped and pasted content is written into the description as Markdown —
/// `![name](file://…)` for an image, `[name](file://…)` for anything else — so
/// `details` stays a plain Markdown string that `agentPrompt` can carry verbatim.
/// When `attachments` is bound (tasks; stories have no attachment list) the same
/// file is also registered as an attachment, which is what actually ships to the
/// agent on dispatch.
///
/// The source editor uses the chat input's `IMETextView`. Editable tokens mark
/// the positions of image and file references in the Markdown. The file chips
/// above the editor open previews and let the user remove an attachment.
struct MarkdownDescriptionEditor: View {
    enum Layout {
        case form
        case composer(onSubmit: () -> Void)
    }

    @Binding var text: String
    var attachments: Binding<[Attachment.DTO]>?
    var placeholder: String
    var title: LocalizedStringKey = "Description"
    var isDisabled: Bool = false
    var height: CGFloat = 170
    /// Prefix for the accessibility identifiers, so two editors can be on
    /// screen at once and still be told apart.
    var identifierPrefix: String = "task-description"
    var editorIdentifier: String?
    var layout: Layout = .form

    @State private var controller = MarkdownEditorController()
    @State private var isDropTargeted = false
    @State private var showsPreview = false
    @State private var chips = DescriptionAttachmentChips()
    @State private var displayText = ""
    @State private var isFocused = false
    @State private var hasMarkedText = false
    @State private var previewAttachment: Attachment?
    @State private var choosingFiles = false

    /// Drops are accepted in preview mode too — the caret is unavailable there,
    /// so `insert` falls back to appending.
    private var acceptsContent: Bool { !isDisabled }

    private var isForm: Bool {
        if case .form = layout { true } else { false }
    }

    var body: some View {
        let items = displayedAttachments
        let field = AttachmentTextField(
            editor: editor,
            attachments: items.filter { $0.type != .file },
            editorHeight: isForm ? height - 12 : nil,
            showsFilePicker: !isForm,
            onAdd: { item, _ in
                attach(item)
                return nil
            },
            onRemove: remove
        )
        return VStack(alignment: .leading, spacing: 6) {
            if isForm { header }
            if !showsPreview { fileChips(items.filter { $0.type == .file }) }
            if isForm {
                formContent(field)
            } else {
                field
            }
        }
        .padding(.vertical, isForm ? 2 : 0)
        .onDrop(of: AttachmentIntake.dropTypes, isTargeted: $isDropTargeted) { providers in
            guard acceptsContent else { return false }
            handleDrop(providers)
            return true
        }
        .overlay { dropHint }
        .sheet(item: $previewAttachment) { AttachmentPreviewSheet(attachment: $0) }
        .rxCodeAttachmentPreviews()
        .onAppear {
            controller.fallbackAppend = { [binding = editorText] snippet in binding.wrappedValue += snippet }
        }
        .onChange(of: text, initial: true) { _, newValue in
            // An external reset starts a fresh draft with its own image tokens.
            guard chips.markdown(for: displayText) != newValue else { return }
            chips = DescriptionAttachmentChips()
            displayText = chips.display(for: newValue)
        }
    }

    private var editorText: Binding<String> {
        Binding(get: { displayText }, set: { value in
            displayText = value
            text = chips.markdown(for: value)
        })
    }

    @ViewBuilder
    private func formContent(_ field: AttachmentTextField) -> some View {
        Group {
            if showsPreview { markdownPreview.frame(height: height) }
            else { field.padding(6) }
        }
        .background(ClaudeTheme.inputBackground, in: shape)
        .overlay {
            shape.strokeBorder(
                isDropTargeted ? ClaudeTheme.accent : ClaudeTheme.inputBorder,
                lineWidth: isDropTargeted ? 1.5 : 1
            )
        }
        if !isDisabled {
            Text("Markdown. Paste or drop images and files to attach them.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            addFilesButton
            Picker("Editor Mode", selection: $showsPreview) {
                Image(systemName: "pencil").tag(false)
                Image(systemName: "eye").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the Markdown source and its preview")
            .accessibilityIdentifier("\(identifierPrefix)-mode")
        }
    }

    private var addFilesButton: some View {
        Button { choosingFiles = true } label: {
            Label("Add Files…", systemImage: "paperclip")
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help("Add Files…")
        .accessibilityIdentifier("\(identifierPrefix)-add-files")
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard acceptsContent, case .success(let urls) = result else { return }
            for url in urls {
                if let attachment = AttachmentFactory.fromFileURL(url) { attach(attachment) }
            }
        }
    }

    private var markdownPreview: some View {
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
    }

    private var font: NSFont {
        switch layout {
        case .form: .monospacedSystemFont(ofSize: ClaudeTheme.size(12), weight: .regular)
        case .composer: .systemFont(ofSize: ClaudeTheme.size(13))
        }
    }

    private var editor: IMETextView {
        IMETextView(
            text: editorText,
            isFocused: $isFocused,
            hasMarkedText: $hasMarkedText,
            font: font,
            textColor: NSColor(isDisabled ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary),
            chipColor: NSColor(ClaudeTheme.accent),
            placeholder: placeholder,
            onReturn: {
                switch layout {
                case .form: controller.insert("\n")
                case .composer(let onSubmit): onSubmit()
                }
            },
            onImageChipTap: { previewAttachment = chips.attachment(at: $0) },
            isEditable: !isDisabled,
            accessibilityIdentifier: editorIdentifier ?? "\(identifierPrefix)-editor",
            onTextViewReady: { [controller] textView in
                // Route dropped files to the SwiftUI drop target instead of inserting a bare path.
                textView.unregisterDraggedTypes()
                controller.textView = textView
            },
            chipThumbnail: { index in
                guard let item = chips.attachment(at: index) else { return nil }
                return item.type == .image ? ChipThumbnailCache.shared.thumbnail(for: item) : NSWorkspace.shared.icon(forFile: item.path)
            },
            chipTokens: chips.indices
        )
    }

    private var displayedAttachments: [Attachment] {
        let inline = chips.attachments(in: displayText)
        let paths = Set(inline.map(\.path))
        let extra = attachments?.wrappedValue.filter { !paths.contains($0.path) }.map(Attachment.init(dto:)) ?? []
        return inline + extra
    }

    @ViewBuilder
    private func fileChips(_ files: [Attachment]) -> some View {
        if !files.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                ForEach(files) { file in fileChip(file) }
            }
        }
    }

    private func fileChip(_ file: Attachment) -> some View {
        HStack(spacing: 2) {
            Button { previewAttachment = file } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(ClaudeTheme.accentText)
                    Text(verbatim: file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 8)
                .padding(.trailing, isDisabled ? 8 : 2)
                .frame(maxWidth: 200, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .help(file.path)
            .accessibilityLabel("Preview \(file.name)")
            .accessibilityIdentifier("attachment-preview-\(file.name)")

            if !isDisabled {
                Button { remove(file) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Remove \(file.name)")
                .accessibilityLabel("Remove \(file.name)")
                .accessibilityIdentifier("attachment-remove-\(file.name)")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(ClaudeTheme.textPrimary)
        .background(ClaudeTheme.surfaceElevated, in: Capsule())
        .overlay { Capsule().strokeBorder(ClaudeTheme.inputBorder).allowsHitTesting(false) }
    }

    private func remove(_ item: Attachment) {
        guard acceptsContent else { return }
        editorText.wrappedValue = chips.removing(item, from: displayText)
        attachments?.wrappedValue.removeAll { $0.path == item.path }
    }

    @ViewBuilder
    private var dropHint: some View {
        if isDropTargeted, acceptsContent {
            shape
                .fill(ClaudeTheme.accent.opacity(0.08))
                .overlay {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .foregroundStyle(ClaudeTheme.accentText)
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: - Paste & Drop

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
            if item.type == .image {
                controller.insert(chips.token(for: reference))
            } else {
                controller.insertBlock(chips.token(for: reference))
            }
            guard let attachments, !item.path.isEmpty else { continue }
            let dto = item.persistableInTaskBoard().dto
            guard !attachments.wrappedValue.contains(where: { $0.path == dto.path }) else { continue }
            attachments.wrappedValue.append(dto)
        }
    }

    /// `![alt](file://…)` for an image, `[label](file://…)` otherwise. The URL
    /// form is used rather than a bare path because Markdown link destinations
    /// end at the first space, and paths routinely contain spaces.
    static func markdownReference(for attachment: Attachment) -> String {
        let label = attachment.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = attachment.path.isEmpty
            ? attachment.name
            : URL(fileURLWithPath: attachment.path).absoluteString
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
        return "\(attachment.type == .image ? "!" : "")[\(label)](\(destination))"
    }

    /// Preserve the chat draft's image positions and include files chosen without an inline token.
    static func markdown(forChatDraft draft: String, files: [Attachment]) -> String {
        guard !files.isEmpty else { return draft }
        let images = files.filter { $0.type == .image }
        let text = draft as NSString
        let result = NSMutableString(string: draft)
        let pattern = try! NSRegularExpression(pattern: #"\[Image(\d+)\]"#)
        var inline: Set<UUID> = []
        for match in pattern.matches(in: draft, range: NSRange(location: 0, length: text.length)).reversed() {
            guard let slot = Int(text.substring(with: match.range(at: 1))), slot > 0, slot <= images.count else { continue }
            let image = images[slot - 1]
            inline.insert(image.id)
            result.replaceCharacters(in: match.range, with: markdownReference(for: image))
        }
        let extra = files.filter { !inline.contains($0.id) }.map(markdownReference)
        return ([result as String] + extra).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - Attachment chips

/// The editable tokens keep a stable slot as the user moves or removes references.
struct DescriptionAttachmentChips {
    private struct Entry {
        let reference: String
        let token: String
        let attachment: Attachment?
    }

    private var entries: [Entry] = []
    private(set) var indices: [String: Int] = [:]
    private var imageCount = 0
    private static let reference = try! NSRegularExpression(pattern: #"!?\[((?:\\.|[^\]\\\n])*)\]\(([^)\s]+)\)"#)
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\[(?:\\.|[^\[\]\\\n])+\]"#)

    mutating func token(for reference: String) -> String {
        if let entry = entries.first(where: { $0.reference == reference }) { return entry.token }
        let ns = reference as NSString
        guard let match = Self.reference.firstMatch(in: reference, range: NSRange(location: 0, length: ns.length)),
              let url = URL(string: ns.substring(with: match.range(at: 2))) else { return reference }
        let image = reference.hasPrefix("!")
        guard image || url.isFileURL else { return reference }

        let label = ns.substring(with: match.range(at: 1))
        let name = label.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        let item = url.isFileURL ? Attachment(type: image ? .image : .file, name: name, path: url.path) : nil
        let token: String
        if image {
            imageCount += 1
            token = Attachment.imageToken(imageCount)
        } else {
            let base = "[File: \(label)]"
            token = indices[base] == nil ? base : "[File \(entries.count + 1): \(label)]"
        }
        entries.append(Entry(reference: reference, token: token, attachment: item))
        indices[token] = entries.count
        return token
    }

    mutating func display(for markdown: String) -> String {
        let ns = markdown as NSString
        let matches = Self.reference.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += token(for: ns.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }

    func markdown(for display: String) -> String {
        let ns = display as NSString
        let result = NSMutableString(string: display)
        for match in Self.tokenPattern.matches(in: display, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let slot = indices[ns.substring(with: match.range)] {
                result.replaceCharacters(in: match.range, with: entries[slot - 1].reference)
            }
        }
        return result as String
    }

    func attachment(at slot: Int) -> Attachment? {
        guard slot > 0, slot <= entries.count else { return nil }
        return entries[slot - 1].attachment
    }

    func attachments(in display: String) -> [Attachment] {
        entries.compactMap { display.contains($0.token) ? $0.attachment : nil }
    }

    func removing(_ item: Attachment, from display: String) -> String {
        guard let entry = entries.first(where: { $0.attachment?.id == item.id }) else { return display }
        return display.replacingOccurrences(of: entry.token, with: "")
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
