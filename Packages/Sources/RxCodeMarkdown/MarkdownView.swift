import SwiftUI
import RxCodeCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct MarkdownStyle {
    public var bodyFontSize: CGFloat
    public var bodyColor: Color
    public var secondaryColor: Color
    public var accentColor: Color
    public var codeTextColor: Color
    public var codeBackground: Color
    public var codeHeaderBackground: Color
    public var borderColor: Color
    public var tableHeaderBackground: Color
    public var lineSpacing: CGFloat
    public var blockSpacing: CGFloat
    public var cornerRadius: CGFloat

    public init(
        bodyFontSize: CGFloat = 15,
        bodyColor: Color = .primary,
        secondaryColor: Color = .secondary,
        accentColor: Color = .accentColor,
        codeTextColor: Color = .primary,
        codeBackground: Color = Color.primary.opacity(0.08),
        codeHeaderBackground: Color = Color.primary.opacity(0.05),
        borderColor: Color = Color.primary.opacity(0.14),
        tableHeaderBackground: Color = Color.primary.opacity(0.05),
        lineSpacing: CGFloat = 3,
        blockSpacing: CGFloat = 8,
        cornerRadius: CGFloat = 6
    ) {
        self.bodyFontSize = bodyFontSize
        self.bodyColor = bodyColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeTextColor = codeTextColor
        self.codeBackground = codeBackground
        self.codeHeaderBackground = codeHeaderBackground
        self.borderColor = borderColor
        self.tableHeaderBackground = tableHeaderBackground
        self.lineSpacing = lineSpacing
        self.blockSpacing = blockSpacing
        self.cornerRadius = cornerRadius
    }

    public func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: bodyFontSize * 1.33
        case 2: bodyFontSize * 1.2
        case 3: bodyFontSize * 1.07
        default: bodyFontSize
        }
    }
}

public final class MarkdownImageCache: @unchecked Sendable {
    public static let shared = MarkdownImageCache()

    #if canImport(AppKit)
    fileprivate let cache = NSCache<NSURL, NSImage>()
    #elseif canImport(UIKit)
    fileprivate let cache = NSCache<NSURL, UIImage>()
    #endif

    public init() {}
}

/// Memoization cache for parsed markdown documents of *settled* messages.
///
/// `MarkdownDocumentParser.parse` is a pure function of its input but is
/// comparatively expensive (full block tree + inline `AttributedString`
/// construction). SwiftUI re-evaluates a view's `body` far more often than the
/// underlying text changes — every sibling-row update, scroll tick, or window
/// resize re-runs it — so an unguarded parse in `body` re-does that work for
/// settled messages that haven't changed at all. Keying on the exact string
/// makes those re-renders cost a lookup instead of a re-parse.
///
/// Streaming/coalesced text is deliberately **never** cached: it is a sequence
/// of unique, growing full-message snapshots, so caching it would retain dozens
/// of near-full copies of the response (plus their parsed trees) for the app's
/// lifetime — memory that reads as a leak after a long stream. Live text is
/// parsed directly via `cacheable: false`. Settled documents above
/// `maxCacheableTextBytes` are also parsed on demand rather than retained, and
/// the underlying `NSCache` is cost-limited so it evicts under memory pressure.
final class MarkdownParseCache: @unchecked Sendable {
    static let shared = MarkdownParseCache()

    private final class Box {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private let cache = NSCache<NSString, Box>()
    /// Settled documents whose source exceeds this size are parsed on demand
    /// rather than cached — avoids holding near-full copies of very large
    /// outputs or logs indefinitely.
    private let maxCacheableTextBytes = 16 * 1024

    private init() {
        cache.totalCostLimit = 4 * 1024 * 1024  // ~4MB of source text
    }

    /// Returns the parsed document for `text`. The cache is consulted and
    /// populated only when `cacheable` is true (settled, reasonably-sized
    /// messages); live/streaming text is always parsed directly and never
    /// stored.
    func document(for text: String, cacheable: Bool) -> MarkdownDocument {
        let cost = text.utf8.count
        guard cacheable, cost <= maxCacheableTextBytes else {
            return MarkdownDocumentParser.parse(text)
        }
        let key = text as NSString
        if let box = cache.object(forKey: key) {
            return box.document
        }
        let parsed = MarkdownDocumentParser.parse(text)
        cache.setObject(Box(parsed), forKey: key, cost: cost)
        return parsed
    }
}

public struct MarkdownView: View {
    public typealias LinkHandler = (URL) -> OpenURLAction.Result

    private static let newTextFadeDuration: Duration = .milliseconds(800)
    /// Maximum cadence at which streaming text is handed to the (expensive)
    /// markdown parse. Caps re-parsing at ~60fps instead of once per token.
    private static let streamCoalesceInterval: Duration = .milliseconds(16)

    private let text: String
    private let showsTrailingCursor: Bool
    private let isCursorVisible: Bool
    private let baseURL: URL?
    private let style: MarkdownStyle
    private let fadeNewText: Bool
    private let expandsHorizontally: Bool
    private let imageCache: MarkdownImageCache
    private let onOpenLink: LinkHandler?

    @State private var observedText: String
    @State private var fadeSegments: [MarkdownFadeSegment] = []
    @State private var fadeTasks: [UUID: Task<Void, Never>] = [:]
    /// The text actually fed to the parser. Lags `text` by at most
    /// `streamCoalesceInterval` so a burst of streaming token deltas collapses
    /// into a single re-parse per frame instead of one per token.
    @State private var displayedText: String
    /// Latest text seen during an active coalescing window, applied when it ends.
    @State private var pendingText: String?
    @State private var coalesceTask: Task<Void, Never>?

    public init(
        text: String,
        showsTrailingCursor: Bool = false,
        isCursorVisible: Bool = true,
        baseURL: URL? = nil,
        style: MarkdownStyle = MarkdownStyle(),
        fadeNewText: Bool = false,
        expandsHorizontally: Bool = true,
        imageCache: MarkdownImageCache = .shared,
        onOpenLink: LinkHandler? = nil
    ) {
        self.text = text
        self.showsTrailingCursor = showsTrailingCursor
        self.isCursorVisible = isCursorVisible
        self.baseURL = baseURL
        self.style = style
        self.fadeNewText = fadeNewText
        self.expandsHorizontally = expandsHorizontally
        self.imageCache = imageCache
        self.onOpenLink = onOpenLink
        _observedText = State(initialValue: text)
        _displayedText = State(initialValue: text)
    }

    public var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        // A live message (streaming cursor and/or fade-in) produces unique,
        // growing snapshots — never cache those, or the cache fills with
        // near-full copies of the response. Only settled text is memoized.
        let isLiveMessage = showsTrailingCursor || fadeNewText
        let view = MarkdownDocumentView(
            document: MarkdownParseCache.shared.document(for: renderedText, cacheable: !isLiveMessage),
            baseURL: baseURL,
            style: style,
            imageCache: imageCache,
            fadeSegments: fadeSegments
        )
        .textSelection(.enabled)
        .frame(maxWidth: expandsHorizontally ? .infinity : nil, alignment: .leading)
        .onChange(of: text) { _, newText in
            coalesceDisplayUpdate(to: newText)
        }
        .onDisappear {
            coalesceTask?.cancel()
            cancelFadeTasks()
        }

        if let onOpenLink {
            view.environment(\.openURL, OpenURLAction { url in
                onOpenLink(url)
            })
        } else {
            view
        }
    }

    private var renderedText: String {
        displayedText
    }

    /// Leading-edge throttle for streaming text.
    ///
    /// The first change renders immediately, so a settled message (a single
    /// update) has no added latency. Subsequent changes inside the cooldown
    /// window are collapsed to the latest value and flushed once when the
    /// window ends. Without this, `MarkdownDocumentParser.parse` runs on every
    /// streamed token — O(n) work per token, O(n²) over a message — which
    /// dominates allocation churn and stalls the main thread mid-stream.
    private func coalesceDisplayUpdate(to newText: String) {
        guard coalesceTask == nil else {
            pendingText = newText
            return
        }
        applyDisplayedText(newText)
        coalesceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.streamCoalesceInterval)
            coalesceTask = nil
            if let pending = pendingText {
                pendingText = nil
                coalesceDisplayUpdate(to: pending)
            }
        }
    }

    private func applyDisplayedText(_ newText: String) {
        displayedText = newText
        updateFadeState(for: newText)
    }

    private func updateFadeState(for newText: String) {
        let oldText = observedText
        observedText = newText

        guard fadeNewText,
              let insertedRange = MarkdownTextDiffer.insertedRange(from: oldText, to: newText) else {
            cancelFadeTasks()
            fadeSegments = []
            return
        }

        if insertedRange.lowerBound != oldText.count {
            cancelFadeTasks()
            fadeSegments = []
        }

        let segment = MarkdownFadeSegment(range: insertedRange, opacity: 0)
        fadeSegments.append(segment)
        fadeTasks[segment.id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.newTextFadeDuration.timeInterval)) {
                setFadeSegmentOpacity(id: segment.id, opacity: 1)
            }
            try? await Task.sleep(for: Self.newTextFadeDuration)
            guard !Task.isCancelled else { return }
            fadeSegments.removeAll { $0.id == segment.id }
            fadeTasks[segment.id] = nil
        }
    }

    private func setFadeSegmentOpacity(id: UUID, opacity: Double) {
        guard let index = fadeSegments.firstIndex(where: { $0.id == id }) else { return }
        fadeSegments[index].opacity = opacity
    }

    private func cancelFadeTasks() {
        fadeTasks.values.forEach { $0.cancel() }
        fadeTasks = [:]
    }
}

private struct MarkdownDocumentView: View {
    let document: MarkdownDocument
    let baseURL: URL?
    let style: MarkdownStyle
    let imageCache: MarkdownImageCache
    let fadeSegments: [MarkdownFadeSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inlines, _):
            InlineMarkdownText(
                inlines: inlines,
                style: style,
                baseURL: baseURL,
                fontSize: style.headingFontSize(level: level),
                weight: level <= 2 ? .bold : .semibold,
                fadeSegments: fadeSegments
            )
            .padding(.top, level <= 2 ? 6 : 3)
        case .paragraph(let inlines, _):
            InlineMarkdownText(
                inlines: inlines,
                style: style,
                baseURL: baseURL,
                fontSize: style.bodyFontSize,
                weight: .regular,
                fadeSegments: fadeSegments
            )
        case .list(let ordered, let items, _):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(item.number ?? itemIndex + 1)." : "-")
                            .font(.system(size: style.bodyFontSize, weight: .semibold))
                            .foregroundStyle(style.accentColor.opacity(opacity(for: item.range)))
                            .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                        InlineMarkdownText(
                            inlines: item.inlines,
                            style: style,
                            baseURL: baseURL,
                            fontSize: style.bodyFontSize,
                            weight: .regular,
                            fadeSegments: fadeSegments
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
        }
        case .quote(let inlines, _):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(style.accentColor)
                    .frame(width: 3)
                InlineMarkdownText(
                    inlines: inlines,
                    style: style,
                    baseURL: baseURL,
                    fontSize: style.bodyFontSize,
                    weight: .regular,
                    overrideColor: style.secondaryColor,
                    fadeSegments: fadeSegments
                )
            }
            .padding(.vertical, 2)
        case .codeBlock(let language, let content, let range):
            MarkdownCodeBlockView(language: language, content: content, style: style)
                .opacity(opacity(for: range))
        case .image(let alt, let source, let range):
            CachedMarkdownImage(
                alt: alt,
                source: source,
                baseURL: baseURL,
                style: style,
                cache: imageCache
            )
            .opacity(opacity(for: range))
        case .table(let headers, let rows, let range):
            MarkdownTableView(headers: headers, rows: rows, baseURL: baseURL, style: style)
                .opacity(opacity(for: range))
        case .divider(let range):
            Rectangle()
                .fill(style.borderColor)
                .frame(height: 1)
                .opacity(opacity(for: range))
        }
    }

    private func opacity(for range: Range<Int>) -> Double {
        // A block-level element fades in only when it first appears. We key the
        // fade off the segment containing the block's start offset rather than
        // any overlapping segment. Otherwise, appending content to an existing
        // block during streaming (e.g. new table rows or code lines) keeps
        // overlapping the newest fade segment and re-fades the whole block on
        // every chunk — which shows up as the block blinking repeatedly.
        fadeSegments
            .filter { $0.range.contains(range.lowerBound) }
            .map(\.opacity)
            .min() ?? 1
    }
}

private struct InlineMarkdownText: View {
    let inlines: [MarkdownInline]
    let style: MarkdownStyle
    let baseURL: URL?
    let fontSize: CGFloat
    let weight: Font.Weight
    var overrideColor: Color?
    let fadeSegments: [MarkdownFadeSegment]

    var body: some View {
        Text(attributedString)
            .font(.system(size: fontSize, weight: weight))
            .lineSpacing(style.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedString: AttributedString {
        var output = AttributedString()
        for inline in inlines {
            output += attributed(inline)
        }
        return output
    }

    private func attributed(_ inline: MarkdownInline) -> AttributedString {
        switch inline {
        case .text(let value, let range):
            return segment(value, range: range, color: overrideColor ?? style.bodyColor, weight: weight)
        case .strong(let value, let range):
            return segment(
                value,
                range: range.removingDelimiters(prefix: 2, suffix: 2),
                color: overrideColor ?? style.bodyColor,
                weight: .semibold
            )
        case .emphasis(let value, let range):
            var attr = segment(
                value,
                range: range.removingDelimiters(prefix: 1, suffix: 1),
                color: overrideColor ?? style.bodyColor,
                weight: weight
            )
            attr.inlinePresentationIntent = .emphasized
            return attr
        case .code(let value, let range):
            let visibleRange = range.removingDelimiters(prefix: 1, suffix: 1)
            var attr = segment(value, range: visibleRange, color: style.codeTextColor, weight: .regular, design: .monospaced)
            attr.backgroundColor = style.codeBackground.opacity(opacity(for: visibleRange))
            return attr
        case .link(let label, let destination, let range):
            let visibleRange = linkLabelRange(label: label, destination: destination, range: range)
            var attr = segment(label, range: visibleRange, color: style.accentColor, weight: weight)
            attr.link = MarkdownDocumentParser.resolvedURL(for: destination, baseURL: baseURL)
            attr.underlineStyle = .single
            return attr
        case .image(let alt, _, let range):
            let label = alt.isEmpty ? "[image]" : alt
            let visibleRange = alt.isEmpty ? range.clampedLength(to: label.count) : range.removingDelimiters(prefix: 2, suffix: 0).clampedLength(to: alt.count)
            return segment(label, range: visibleRange, color: style.secondaryColor, weight: weight)
        }
    }

    private func segment(
        _ value: String,
        range: Range<Int>,
        color: Color,
        weight: Font.Weight,
        design: Font.Design = .default
    ) -> AttributedString {
        var output = AttributedString()
        for part in MarkdownFadeSplitter.split(value, range: range, fadeSegments: fadeSegments) {
            var attr = AttributedString(part.value)
            attr.font = .system(size: fontSize, weight: weight, design: design)
            attr.foregroundColor = color.opacity(part.opacity)
            output += attr
        }
        return output
    }

    private func opacity(for range: Range<Int>) -> Double {
        fadeSegments
            .filter { $0.range.overlaps(range) }
            .map(\.opacity)
            .min() ?? 1
    }

    private func linkLabelRange(label: String, destination: String, range: Range<Int>) -> Range<Int> {
        if label == destination, range.count == label.count {
            return range
        }
        return range.removingDelimiters(prefix: 1, suffix: 0).clampedLength(to: label.count)
    }
}

struct MarkdownFadeSegment: Equatable, Identifiable {
    let id: UUID
    var range: Range<Int>
    var opacity: Double

    init(id: UUID = UUID(), range: Range<Int>, opacity: Double) {
        self.id = id
        self.range = range
        self.opacity = opacity
    }
}

struct MarkdownFadePart: Equatable {
    var value: String
    var shouldFade: Bool
    var opacity: Double

    init(value: String, shouldFade: Bool, opacity: Double? = nil) {
        self.value = value
        self.shouldFade = shouldFade
        self.opacity = opacity ?? (shouldFade ? 0 : 1)
    }
}

enum MarkdownFadeSplitter {
    static func split(
        _ value: String,
        range: Range<Int>,
        fadeSegments: [MarkdownFadeSegment]
    ) -> [MarkdownFadePart] {
        let intersectingSegments = fadeSegments.filter { $0.range.overlaps(range) }
        guard !intersectingSegments.isEmpty else {
            return [MarkdownFadePart(value: value, shouldFade: false)]
        }

        let boundaries = Set(
            [range.lowerBound, range.upperBound] +
            intersectingSegments.flatMap { segment in
                [
                    max(range.lowerBound, segment.range.lowerBound),
                    min(range.upperBound, segment.range.upperBound),
                ]
            }
        )
        let sortedBoundaries = boundaries.sorted()

        return zip(sortedBoundaries, sortedBoundaries.dropFirst()).compactMap { lowerBound, upperBound in
            guard lowerBound < upperBound else { return nil }
            let partRange = lowerBound..<upperBound
            let opacity = intersectingSegments
                .filter { $0.range.overlaps(partRange) }
                .map(\.opacity)
                .min() ?? 1
            let startOffset = min(max(0, lowerBound - range.lowerBound), value.count)
            let endOffset = min(max(0, upperBound - range.lowerBound), value.count)
            guard startOffset < endOffset else { return nil }
            let startIndex = value.index(value.startIndex, offsetBy: startOffset)
            let endIndex = value.index(value.startIndex, offsetBy: endOffset)
            return MarkdownFadePart(
                value: String(value[startIndex..<endIndex]),
                shouldFade: opacity < 1,
                opacity: opacity
            )
        }
    }
}

enum MarkdownTextDiffer {
    static func insertedRange(from oldText: String, to newText: String) -> Range<Int>? {
        guard oldText != newText, newText.count > oldText.count else {
            return nil
        }

        let prefixLength = commonPrefixLength(oldText, newText)
        let suffixLength = commonSuffixLength(
            oldText,
            newText,
            excludingPrefixLength: prefixLength
        )
        let insertedEnd = newText.count - suffixLength
        guard prefixLength < insertedEnd else {
            return nil
        }

        return prefixLength..<insertedEnd
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex

        while lhsIndex < lhs.endIndex,
              rhsIndex < rhs.endIndex,
              lhs[lhsIndex] == rhs[rhsIndex] {
            length += 1
            lhs.formIndex(after: &lhsIndex)
            rhs.formIndex(after: &rhsIndex)
        }

        return length
    }

    private static func commonSuffixLength(
        _ lhs: String,
        _ rhs: String,
        excludingPrefixLength prefixLength: Int
    ) -> Int {
        var length = 0
        var lhsIndex = lhs.endIndex
        var rhsIndex = rhs.endIndex
        let maximumLength = min(lhs.count, rhs.count) - prefixLength

        while length < maximumLength {
            let previousLHSIndex = lhs.index(before: lhsIndex)
            let previousRHSIndex = rhs.index(before: rhsIndex)
            guard lhs[previousLHSIndex] == rhs[previousRHSIndex] else { break }
            length += 1
            lhsIndex = previousLHSIndex
            rhsIndex = previousRHSIndex
        }

        return length
    }
}

private extension Range where Bound == Int {
    var count: Int {
        upperBound - lowerBound
    }

    func removingDelimiters(prefix: Int, suffix: Int) -> Range<Int> {
        let lower = Swift.min(upperBound, lowerBound + prefix)
        let upper = Swift.max(lower, upperBound - suffix)
        return lower..<upper
    }

    func clampedLength(to length: Int) -> Range<Int> {
        lowerBound..<Swift.min(upperBound, lowerBound + length)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let content: String
    let style: MarkdownStyle
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: style.bodyFontSize * 0.73, weight: .medium, design: .monospaced))
                        .foregroundStyle(style.secondaryColor)
                }
                Spacer()
                Button {
                    copyToPasteboard(content)
                    withAnimation { isCopied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { isCopied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2)
                    }
                    .foregroundStyle(isCopied ? Color.green : style.secondaryColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(style.codeHeaderBackground)

            Rectangle()
                .fill(style.borderColor)
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                codeText
                    .lineSpacing(style.lineSpacing)
                    .fixedSize()
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .strokeBorder(style.borderColor, lineWidth: 0.5)
        )
    }

    /// Syntax-highlighted code when a language is specified,
    /// otherwise plain monospaced text in the theme's code color.
    private var codeText: Text {
        let fontSize = style.bodyFontSize * 0.88
        if let language, !language.isEmpty {
            return Text(SyntaxHighlighter.highlight(content, language: language, fontSize: fontSize))
        }
        return Text(content)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundColor(style.codeTextColor)
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let baseURL: URL?
    let style: MarkdownStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        cell(header, weight: .semibold, color: style.bodyColor)
                            .padding(.vertical, 5)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(headers.count, row.count), id: \.self) { index in
                            cell(index < row.count ? row[index] : "", weight: .regular, color: style.secondaryColor)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(10)
            .background(style.tableHeaderBackground, in: RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .strokeBorder(style.borderColor, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func cell(_ content: String, weight: Font.Weight, color: Color) -> some View {
        InlineMarkdownText(
            inlines: MarkdownDocumentParser.parseInlines(content),
            style: style,
            baseURL: baseURL,
            fontSize: style.bodyFontSize * 0.92,
            weight: weight,
            overrideColor: color,
            fadeSegments: []
        )
    }
}

private struct CachedMarkdownImage: View {
    let alt: String
    let source: String
    let baseURL: URL?
    let style: MarkdownStyle
    let cache: MarkdownImageCache

    @State private var phase: ImagePhase = .idle

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .fill(style.codeBackground)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
            case .loaded(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            case .failed:
                Text(alt.isEmpty ? source : alt)
                    .font(.caption)
                    .foregroundStyle(style.secondaryColor)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(style.codeBackground, in: RoundedRectangle(cornerRadius: style.cornerRadius))
            }
        }
        .task(id: source) {
            await load()
        }
    }

    private func load() async {
        guard let url = MarkdownDocumentParser.resolvedURL(for: source, baseURL: baseURL) else {
            phase = .failed
            return
        }
        if case .loaded = phase { return }
        phase = .loading

        #if canImport(AppKit)
        if let cached = cache.cache.object(forKey: url as NSURL) {
            phase = .loaded(Image(nsImage: cached))
            return
        }
        #elseif canImport(UIKit)
        if let cached = cache.cache.object(forKey: url as NSURL) {
            phase = .loaded(Image(uiImage: cached))
            return
        }
        #endif

        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                data = try await URLSession.shared.data(for: request).0
            }

            #if canImport(AppKit)
            guard let nativeImage = NSImage(data: data) else {
                phase = .failed
                return
            }
            cache.cache.setObject(nativeImage, forKey: url as NSURL)
            phase = .loaded(Image(nsImage: nativeImage))
            #elseif canImport(UIKit)
            guard let nativeImage = UIImage(data: data) else {
                phase = .failed
                return
            }
            cache.cache.setObject(nativeImage, forKey: url as NSURL)
            phase = .loaded(Image(uiImage: nativeImage))
            #else
            phase = .failed
            #endif
        } catch {
            phase = .failed
        }
    }

    private enum ImagePhase {
        case idle
        case loading
        case loaded(Image)
        case failed
    }
}

private func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
}

#Preview("MarkdownView") {
    ScrollView {
        MarkdownView(
            text: """
            # Pure SwiftUI Markdown

            This renderer supports **bold**, *italic*, `inline code`, [custom links](https://example.com), and bare URLs like https://rxlab.dev.

            > Block quotes stay native SwiftUI.

            - Cached network image support
            - Custom component style
            - Fade in appended text

            | Component | Status |
            | --- | --- |
            | **Parser** | `Native` |
            | [Images](https://rxlab.dev) | *Cached* |

            ```swift
            MarkdownView(text: markdown, fadeNewText: true)
            ```
            """,
            fadeNewText: true
        )
        .padding(24)
    }
    .frame(width: 520, height: 620)
}
