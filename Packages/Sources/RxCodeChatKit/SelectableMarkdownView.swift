#if os(macOS)
import AgentMarkdownUI
import AppKit
import RxCodeCore
import SwiftUI

/// AppKit uses one text storage for the entire document, so a selection can
/// extend across headings, paragraphs, list items, and other Markdown blocks.
struct SelectableMarkdownView: NSViewRepresentable {
    @Environment(\.openURL) private var openURL

    let text: String
    let baseURL: URL?
    let style: MarkdownStyle
    let expandsHorizontally: Bool
    let onOpenLink: MarkdownView.LinkHandler?
    let markedRanges: [NSRange]
    let strikeProgress: CGFloat?
    let openAnnotation: ((Int, CGRect) -> Void)?

    func makeNSView(context: Context) -> MarkdownTextView {
        MarkdownTextView(usingTextLayoutManager: false)
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.openLink = { url in
            if let onOpenLink {
                OpenURLAction(handler: onOpenLink)(url)
            } else {
                openURL(url)
            }
        }
        view.openAnnotation = openAnnotation
        view.display(text: text, baseURL: baseURL, style: style, markedRanges: markedRanges, striking: strikeProgress != nil)
        if let strikeProgress { view.setStrikeProgress(strikeProgress) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width, expandsHorizontally: expandsHorizontally)
    }

    static func dismantleNSView(_ view: MarkdownTextView, coordinator: ()) {
        view.cancelImageLoads()
    }
}

final class MarkdownTextView: NSTextView, NSTextViewDelegate {
    private struct Input: Equatable {
        var text: String
        var baseURL: URL?
        var colors: [Color]
        var metrics: [CGFloat]
        var markedRanges: [NSRange]
        var striking: Bool
    }

    private var input: Input?
    private var codeButtons: [(header: Int, code: String, button: NSButton)] = []
    private var imageTasks: [Task<Void, Never>] = []
    var openLink: ((URL) -> Void)?
    var openAnnotation: ((Int, CGRect) -> Void)?
    private var strikeRanges: [NSRange] = []
    private var strikeProgress: CGFloat = 0

    func cancelImageLoads() {
        for task in imageTasks { task.cancel() }
        imageTasks.removeAll()
    }

    func display(text: String, baseURL: URL?, style: MarkdownStyle, markedRanges: [NSRange] = [], striking: Bool = false) {
        let next = Input(text: text, baseURL: baseURL,
                         colors: [style.bodyColor, style.secondaryColor, style.accentColor, style.codeTextColor,
                                  style.codeBackground, style.codeHeaderBackground, style.borderColor, style.tableHeaderBackground],
                         metrics: [style.bodyFontSize, style.lineSpacing, style.blockSpacing],
                         markedRanges: markedRanges, striking: striking)
        guard input != next else { return }
        let previousSelection = input?.text == text ? selectedRange() : nil
        input = next

        isEditable = false
        isSelectable = true
        isRichText = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = false
        delegate = self
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        // Links and change annotations style themselves; AppKit's default link
        // attributes would recolor every annotated passage in the accent color.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]

        let document = MarkdownTextDocument(text: text, baseURL: baseURL, style: style, markedRanges: markedRanges, striking: striking)
        setStrikeProgress(0)
        strikeRanges = document.strikeRanges
        textStorage?.setAttributedString(document.content)
        if let previousSelection, NSMaxRange(previousSelection) <= document.content.length {
            setSelectedRange(previousSelection)
        }

        for item in codeButtons { item.button.removeFromSuperview() }
        codeButtons = document.codeBlocks.enumerated().map { index, block in
            let button = NSButton(title: String(localized: "Copy", bundle: .module), target: self, action: #selector(copyCode(_:)))
            button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            button.font = .systemFont(ofSize: style.bodyFontSize * 0.73)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.tag = index
            button.sizeToFit()
            addSubview(button)
            return (block.header, block.code, button)
        }

        cancelImageLoads()
        imageTasks = document.images.map { image in
            Task { [weak self] in
                guard let data = try? await Self.loadImage(at: image.url), !Task.isCancelled,
                      let nativeImage = NSImage(data: data), nativeImage.isValid, let self else { return }
                let attachment = NSTextAttachment()
                attachment.attachmentCell = MarkdownImageCell(image: nativeImage)
                textStorage?.addAttribute(.attachment, value: attachment, range: image.range)
                invalidateIntrinsicContentSize()
                needsLayout = true
                needsDisplay = true
            }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @concurrent private static func loadImage(at url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        return try await URLSession.shared.data(for: request).0
    }

    func measure(width proposedWidth: CGFloat?, expandsHorizontally: Bool) -> CGSize {
        guard let textContainer, let layoutManager else { return .zero }
        if let proposedWidth, proposedWidth <= 0 { return .zero }
        let width = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 640
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let measuredWidth = expandsHorizontally && proposedWidth?.isFinite == true ? width : min(width, ceil(used.maxX))
        return CGSize(width: measuredWidth, height: ceil(used.maxY))
    }

    override func layout() {
        super.layout()
        guard let textContainer, let layoutManager else { return }
        textContainer.containerSize = NSSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)
        for item in codeButtons {
            let glyph = layoutManager.glyphIndexForCharacter(at: item.header)
            let headerRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            var frame = item.button.frame
            frame.origin = NSPoint(x: max(headerRect.minX, headerRect.maxX - frame.width), y: headerRect.midY - frame.height / 2)
            item.button.frame = frame
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let openAnnotation, let storage = textStorage, (0..<storage.length).contains(charIndex),
           let index = storage.attribute(.markdownAnnotation, at: charIndex, effectiveRange: nil) as? Int,
           let layoutManager, let textContainer {
            let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            openAnnotation(index, rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        guard let url = link as? URL, let openLink else { return false }
        openLink(url)
        return true
    }

    func setStrikeProgress(_ progress: CGFloat) {
        guard progress != strikeProgress, let layoutManager else { return }
        for range in strikeRanges {
            let before = Int(ceil(CGFloat(range.length) * strikeProgress))
            let after = Int(ceil(CGFloat(range.length) * progress))
            let changed = NSRange(location: range.location + min(before, after), length: abs(before - after))
            guard changed.length > 0 else { continue }
            if after > before {
                layoutManager.addTemporaryAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor
                ], forCharacterRange: changed)
            } else {
                layoutManager.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: changed)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: changed)
            }
        }
        strikeProgress = progress
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard codeButtons.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codeButtons[sender.tag].code, forType: .string)
        sender.title = String(localized: "Copied", bundle: .module)
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        sender.sizeToFit()
        needsLayout = true
        Task { [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(2))
            guard let sender else { return }
            sender.title = String(localized: "Copy", bundle: .module)
            sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            sender.sizeToFit()
            self?.needsLayout = true
        }
    }
}

private final class MarkdownTextDocument {
    struct ImageRequest {
        var url: URL
        var range: NSRange
    }

    let content = NSMutableAttributedString()
    private(set) var codeBlocks: [(header: Int, code: String)] = []
    private(set) var images: [ImageRequest] = []
    private(set) var strikeRanges: [NSRange] = []
    private var sourceMap: MarkdownSourceMap?
    private let style: MarkdownStyle
    private let baseURL: URL?
    private var tables: [Int: NSTextTable] = [:]
    private var quoteBlocks: [Int: NSTextTableBlock] = [:]

    init(text: String, baseURL: URL?, style: MarkdownStyle, markedRanges: [NSRange], striking: Bool) {
        self.style = style
        self.baseURL = baseURL
        if !markedRanges.isEmpty { sourceMap = MarkdownSourceMap(markdown: text) }
        let parsed = (try? AttributedString(markdown: text, options: .init(
            failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: sourceMap != nil)))
            ?? AttributedString(text)
        var previous: [PresentationIntent.IntentType] = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            appendBlock(parsed[range], components: components, previous: previous)
            previous = components
        }
        if content.length > 0 {
            content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
        }
        if let sourceMap { mark(markedRanges, in: sourceMap, striking: striking) }
    }

    private func mark(_ ranges: [NSRange], in map: MarkdownSourceMap, striking: Bool) {
        var markers: [(offset: Int, index: Int)] = []
        for (index, source) in ranges.enumerated() {
            let visible = map.renderedRanges(for: source)
            if striking {
                strikeRanges.append(contentsOf: visible)
            } else if visible.isEmpty {
                markers.append((min(content.length, map.insertionPoint(for: source.location)), index))
            } else {
                for range in visible { content.addAttributes(annotationAttributes(index), range: range) }
            }
        }
        // Insert from the end so the source map still addresses the original layout.
        for (offset, index) in markers.sorted(by: { ($0.offset, $0.index) > ($1.offset, $1.index) }) {
            var attributes = annotationAttributes(index)
            attributes[.font] = NSFont.systemFont(ofSize: style.bodyFontSize)
            attributes[.foregroundColor] = NSColor(style.accentColor)
            attributes[.underlineStyle] = nil
            attributes[.toolTip] = String(localized: "Show change details", bundle: .module)
            if content.length > 0 {
                attributes[.paragraphStyle] = content.attribute(.paragraphStyle, at: min(offset, content.length - 1), effectiveRange: nil)
            }
            let marker = NSAttributedString(string: "⌫", attributes: attributes)
            content.insert(marker, at: offset)
            for i in codeBlocks.indices where codeBlocks[i].header >= offset { codeBlocks[i].header += marker.length }
            for i in images.indices where images[i].range.location >= offset { images[i].range.location += marker.length }
        }
    }

    /// Changed passages keep their regular text color and get a quiet dotted
    /// underline, so a heavily revised document still reads like a document.
    private func annotationAttributes(_ index: Int) -> [NSAttributedString.Key: Any] {
        [.markdownAnnotation: index, .link: URL(string: "rxcode-annotation:\(index)")!,
         .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
         .underlineColor: NSColor(style.accentColor).withAlphaComponent(0.6)]
    }

    private func appendBlock(
        _ block: AttributedSubstring,
        components: [PresentationIntent.IntentType],
        previous: [PresentationIntent.IntentType]
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacingBefore = content.length == 0 ? 0 : style.blockSpacing
        var size = style.bodyFontSize
        var weight: NSFont.Weight = .regular
        var color = style.bodyColor
        switch components.first?.kind {
        case .header(let level):
            size = style.headingFontSize(level: level)
            weight = level <= 2 ? .bold : .semibold
        case .codeBlock(let language):
            appendCode(String(block.characters), language: language, paragraph: paragraph, position: block.runs.first?.markdownSourcePosition)
            return
        case .tableCell(let column):
            let cell = tableCell(column: column, components: components)
            paragraph.textBlocks = cell.map { [$0] } ?? []
            paragraph.paragraphSpacingBefore = 0
            size *= 0.92
            if components.contains(where: { $0.kind == .tableHeaderRow }) {
                weight = .semibold
            } else {
                color = style.secondaryColor
            }
        case .thematicBreak:
            let rule = blockCell(table: NSTextTable(), row: 0, column: 0, background: style.borderColor, padding: 0)
            paragraph.textBlocks = [rule]
            append(" \n", font: .systemFont(ofSize: 1), color: color, paragraph: paragraph)
            return
        default:
            break
        }

        let quote = components.first(where: { $0.kind == .blockQuote })
        if let quote {
            color = style.secondaryColor
            if paragraph.textBlocks.isEmpty {
                paragraph.textBlocks = [quoteBlock(identity: quote.identity)]
                paragraph.paragraphSpacingBefore = 0
            }
        }

        if let itemIndex = components.firstIndex(where: {
            if case .listItem = $0.kind { return true }
            return false
        }), case .listItem(let number) = components[itemIndex].kind {
            let list = components.dropFirst(itemIndex + 1).first
            let ordered = list?.kind == .orderedList
            let marker = ordered ? "\(number)." : "-"
            let nesting = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count - 1
            paragraph.firstLineHeadIndent += CGFloat(max(0, nesting)) * 18
            let markerFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            let markerWidth = (marker as NSString).size(withAttributes: [.font: markerFont]).width
            paragraph.headIndent = paragraph.firstLineHeadIndent + max(12, ceil(markerWidth)) + 8
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            if let list, previous.contains(where: { $0.identity == list.identity }) {
                paragraph.paragraphSpacingBefore = 5
            }
            if !previous.contains(where: { $0.identity == components[itemIndex].identity }) {
                append(marker + "\t", font: markerFont, color: style.accentColor, paragraph: paragraph)
            } else {
                paragraph.firstLineHeadIndent = paragraph.headIndent
            }
        }

        for run in block.runs {
            let start = content.length
            defer { sourceMap?.record(run.markdownSourcePosition, in: content, from: start) }
            let value = String(block[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if let imageURL = run.imageURL, block.runs.count == 1 {
                appendImage(url: imageURL, alt: value, paragraph: paragraph)
                continue
            }
            if intent.contains(.inlineHTML) || intent.contains(.blockHTML),
               let image = Self.htmlImage(value) {
                appendImage(url: image.url, alt: image.alt, paragraph: paragraph)
                continue
            }
            let isCode = intent.contains(.code)
            let runWeight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .semibold : weight
            var font = isCode ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size, weight: runWeight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let link = run.link.map(resolve)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(link != nil ? style.accentColor : isCode ? style.codeTextColor : color),
                .paragraphStyle: paragraph
            ]
            attributes[.link] = link
            if link != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if isCode { attributes[.backgroundColor] = NSColor(style.codeBackground) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let visible = quote != nil && intent.contains(.softBreak) ? "\n" : value
            content.append(NSAttributedString(string: visible, attributes: attributes))
        }
        append("\n", font: .systemFont(ofSize: size, weight: weight), color: color, paragraph: paragraph)
    }

    private func appendCode(_ source: String, language: String?, paragraph: NSMutableParagraphStyle, position: AttributedString.MarkdownSourcePosition?) {
        let code = source.hasSuffix("\n") ? String(source.dropLast()) : source
        let table = NSTextTable()
        table.numberOfColumns = 1
        let header = paragraph.mutableCopy() as! NSMutableParagraphStyle
        header.textBlocks = [blockCell(table: table, row: 0, column: 0, background: style.codeHeaderBackground, padding: 6)]
        codeBlocks.append((content.length, code))
        let label = (language?.isEmpty == false ? language : nil) ?? " "
        append(label + "\n", font: .monospacedSystemFont(ofSize: style.bodyFontSize * 0.73, weight: .medium),
               color: style.secondaryColor, paragraph: header)
        paragraph.paragraphSpacingBefore = 0
        paragraph.textBlocks = [blockCell(table: table, row: 1, column: 0, background: style.codeBackground, padding: 12)]
        let size = style.bodyFontSize * 0.88
        let start = content.length
        if let language, !language.isEmpty, !code.isEmpty {
            let highlighted = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlightNS(
                code, language: language, fontSize: size, colors: ThemeStore.shared.colors
            ))
            highlighted.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: highlighted.length))
            content.append(highlighted)
        } else {
            append(code, font: .monospacedSystemFont(ofSize: size, weight: .regular), color: style.codeTextColor, paragraph: paragraph)
        }
        sourceMap?.record(position, in: content, from: start, codeBlock: true)
        append("\n", font: .monospacedSystemFont(ofSize: size, weight: .regular), color: style.codeTextColor, paragraph: paragraph)
    }

    private func tableCell(column: Int, components: [PresentationIntent.IntentType]) -> NSTextTableBlock? {
        guard let tableIntent = components.last, case .table(let columns) = tableIntent.kind,
              let rowIntent = components.dropFirst().first else { return nil }
        let row: Int
        switch rowIntent.kind {
        case .tableHeaderRow: row = 0
        case .tableRow(let number): row = number
        default: return nil
        }
        let table = tables[tableIntent.identity] ?? NSTextTable()
        table.numberOfColumns = columns.count
        table.collapsesBorders = true
        tables[tableIntent.identity] = table
        let cell = blockCell(table: table, row: row, column: column, background: style.tableHeaderBackground, padding: 7)
        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
        cell.setBorderColor(NSColor(style.borderColor))
        return cell
    }

    private func blockCell(table: NSTextTable, row: Int, column: Int, background: Color, padding: CGFloat) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.backgroundColor = NSColor(background)
        cell.setWidth(padding, type: .absoluteValueType, for: .padding)
        if row == 0, content.length > 0 {
            cell.setWidth(style.blockSpacing, type: .absoluteValueType, for: .margin, edge: .minY)
        }
        return cell
    }

    private func quoteBlock(identity: Int) -> NSTextTableBlock {
        if let block = quoteBlocks[identity] { return block }
        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = blockCell(table: table, row: 0, column: 0, background: .clear, padding: 0)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(NSColor(style.accentColor), for: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        quoteBlocks[identity] = block
        return block
    }

    private func appendImage(url: URL, alt: String, paragraph: NSParagraphStyle) {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(textCell: alt.isEmpty ? url.lastPathComponent : alt)
        let text = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: content.length, length: text.length)
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        content.append(text)
        images.append(ImageRequest(url: resolve(url), range: range))
    }

    private func append(_ text: String, font: NSFont, color: Color, paragraph: NSParagraphStyle) {
        content.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(color), .paragraphStyle: paragraph
        ]))
    }

    private func resolve(_ url: URL) -> URL {
        if url.scheme != nil { return url.absoluteURL }
        if let baseURL, let resolved = URL(string: url.relativeString, relativeTo: baseURL) { return resolved.absoluteURL }
        let fileURL = URL(fileURLWithPath: url.path)
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: true)
        components?.fragment = url.fragment
        return components?.url ?? fileURL
    }

    private static func htmlImage(_ text: String) -> (url: URL, alt: String)? {
        guard let tag = text.wholeMatch(of: #/(?is)\s*<img\b(?<attributes>.*?)\/?>\s*/#) else { return nil }
        let attributes = tag.attributes.matches(of: #/(?i)\s(?<name>src|alt)\s*=\s*(?:"(?<double>[^"]*)"|'(?<single>[^']*)'|(?<unquoted>[^\s>]+))/#)
        var source: String?
        var alt: String?
        for match in attributes {
            let value = match.double ?? match.single ?? match.unquoted
            if match.name.lowercased() == "src" { source = value.map(String.init) }
            else { alt = value.map(String.init) }
        }
        guard let source, !source.isEmpty, let url = URL(string: source) else { return nil }
        return (url, alt ?? "")
    }
}

private final class MarkdownImageCell: NSTextAttachmentCell {
    private let imageSize: NSSize

    init(image: NSImage) {
        imageSize = image.size
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        imageSize = .zero
        super.init(coder: coder)
    }

    override nonisolated func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard imageSize.width > 0 else {
            return super.cellFrame(for: textContainer, proposedLineFragment: lineFrag,
                                   glyphPosition: position, characterIndex: charIndex)
        }
        let scale = min(1, max(1, lineFrag.width - position.x) / imageSize.width)
        return NSRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
#endif
