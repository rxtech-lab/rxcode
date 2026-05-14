import SwiftUI
import AppKit
import RxCodeCore

public struct FileDiffView: View {
    public let filePath: String
    public let fileName: String
    public let editHunks: [PreviewFile.EditHunk]
    public let gitDiffMode: PreviewFile.GitDiffMode?
    @Environment(WindowState.self) private var windowState
    @State private var diffLines: [DiffLine] = []
    @State private var isLoading = true
    @State private var isCopied = false

    public init(
        filePath: String,
        fileName: String,
        editHunks: [PreviewFile.EditHunk] = [],
        gitDiffMode: PreviewFile.GitDiffMode? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.editHunks = editHunks
        self.gitDiffMode = gitDiffMode
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            contentArea
        }
        .background(ClaudeTheme.background)
        .background {
            Button("") { windowState.diffFile = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        .task(id: filePath) { await loadDiff() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.accent)

            Text(fileName)
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .semibold, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("Diff", bundle: .module)
                .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ClaudeTheme.surfaceSecondary, in: Capsule())

            if !diffLines.isEmpty {
                Button {
                    let raw = diffLines.map(\.text).joined(separator: "\n")
                    copyToClipboard(raw, feedback: $isCopied)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(isCopied ? ClaudeTheme.statusSuccess : ClaudeTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(isCopied ? "Copied" : "Copy")
            }

            Button { windowState.diffFile = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(ClaudeTheme.surfaceSecondary, in: Circle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudeTheme.surfacePrimary)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(ClaudeTheme.codeBackground)
        } else if diffLines.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: ClaudeTheme.messageSize(24)))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                Text("No changes", bundle: .module)
                    .font(.system(size: ClaudeTheme.messageSize(13)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(ClaudeTheme.codeBackground)
        } else {
            diffContentView
        }
    }

    private var diffContentView: some View {
        DiffTextRenderer(lines: diffLines, language: language)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClaudeTheme.codeBackground)
    }

    private var language: String {
        URL(fileURLWithPath: filePath).pathExtension.lowercased()
    }

    // MARK: - Diff Sources

    private func loadDiff() async {
        isLoading = true
        defer { isLoading = false }

        if !editHunks.isEmpty {
            let hunks = editHunks
            diffLines = await Task.detached(priority: .userInitiated) {
                FileDiffView.buildEditDiffLines(from: hunks)
            }.value
            return
        }

        let workDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        if case .untracked = gitDiffMode {
            let contents = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
            let hunks = [PreviewFile.EditHunk(oldString: "", newString: contents)]
            diffLines = await Task.detached(priority: .userInitiated) {
                FileDiffView.buildEditDiffLines(from: hunks)
            }.value
            return
        }
        let raw: String
        switch gitDiffMode {
        case .unstaged:
            raw = await GitHelper.run(["diff", "--", filePath], at: workDir) ?? ""
        case .staged:
            raw = await GitHelper.run(["diff", "--cached", "--", filePath], at: workDir) ?? ""
        case .untracked:
            raw = ""
        case .none:
            if let r1 = await GitHelper.run(["diff", "HEAD", "--", filePath], at: workDir) {
                raw = r1
            } else if let r2 = await GitHelper.run(["diff", "--", filePath], at: workDir) {
                raw = r2
            } else {
                raw = await GitHelper.run(["show", "HEAD", "--", filePath], at: workDir) ?? ""
            }
        }
        diffLines = await Task.detached(priority: .userInitiated) {
            FileDiffView.parseDiff(raw)
        }.value
    }

    nonisolated static func buildEditDiffLines(from hunks: [PreviewFile.EditHunk]) -> [DiffLine] {
        var lines: [DiffLine] = []
        for (index, hunk) in hunks.enumerated() {
            if hunks.count > 1 {
                lines.append(DiffLine(text: "@@ edit \(index + 1) of \(hunks.count) @@", kind: .hunk))
            }
            let (trimmedOld, trimmedNew) = stripCommonIndent(
                old: hunk.oldString.components(separatedBy: .newlines),
                new: hunk.newString.components(separatedBy: .newlines)
            )
            lines.append(contentsOf: trimmedOld.map { DiffLine(text: "-" + $0, kind: .removed) })
            lines.append(contentsOf: trimmedNew.map { DiffLine(text: "+" + $0, kind: .added) })
        }
        return lines
    }

    nonisolated static func parseDiff(_ raw: String) -> [DiffLine] {
        guard !raw.isEmpty else { return [] }
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { line in
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                return DiffLine(text: line, kind: .added)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                return DiffLine(text: line, kind: .removed)
            } else if line.hasPrefix("@@") {
                return DiffLine(text: line, kind: .hunk)
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                return DiffLine(text: line, kind: .meta)
            } else {
                return DiffLine(text: line, kind: .context)
            }
        }
    }
}

// MARK: - Diff Line Model

struct DiffLine {
    enum Kind {
        case added, removed, hunk, meta, context

        var foregroundColor: Color {
            switch self {
            case .added:   return ClaudeTheme.statusSuccess
            case .removed: return ClaudeTheme.statusError
            case .hunk:    return ClaudeTheme.textTertiary
            case .meta:    return ClaudeTheme.textTertiary
            case .context: return ClaudeTheme.textPrimary
            }
        }
    }

    let text: String
    let kind: Kind
}

// MARK: - Shared Indent Utility

nonisolated func stripCommonIndent(old: [String], new: [String]) -> (old: [String], new: [String]) {
    let combined = old + new
    let commonIndent = combined
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        .min() ?? 0
    guard commonIndent > 0 else { return (old, new) }
    func strip(_ line: String) -> String {
        line.count >= commonIndent ? String(line.dropFirst(commonIndent)) : line
    }
    return (old.map(strip), new.map(strip))
}

// MARK: - NSTextView-based Renderer (TextKit2)

private struct DiffTextRenderer: NSViewRepresentable {
    let lines: [DiffLine]
    let language: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        // Disable auto horizontal resize: forces NSTextView to lay out the entire
        // document up front to compute frame width. We size the container manually
        // so TextKit2's viewport-based vertical layout stays lazy.
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        if let container = textView.textContainer {
            // Bounded width = TextKit2 keeps vertical layout lazy (viewport-only),
            // long lines wrap to fit visible area, no full-document layout pass.
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            container.lineFragmentPadding = 0
        }

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, lines: lines, language: language)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.update(textView: textView, lines: lines, language: language)
    }

    final class Coordinator {
        private weak var textView: NSTextView?
        private var lastLines: [DiffLine] = []
        private var lastLanguage: String = ""
        private var lastFingerprint: Int = 0
        nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

        deinit {
            if let observer = themeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(textView: NSTextView, lines: [DiffLine], language: String) {
            self.textView = textView
            apply(lines: lines, language: language, to: textView)
            registerThemeObserver()
        }

        func update(textView: NSTextView, lines: [DiffLine], language: String) {
            let fp = fingerprint(of: lines, language: language)
            if fp == lastFingerprint, textView === self.textView { return }
            self.textView = textView
            apply(lines: lines, language: language, to: textView)
        }

        private func registerThemeObserver() {
            guard themeObserver == nil else { return }
            themeObserver = NotificationCenter.default.addObserver(
                forName: .rxcodeThemeDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tv = self.textView else { return }
                    self.apply(lines: self.lastLines, language: self.lastLanguage, to: tv)
                }
            }
        }

        private func apply(lines: [DiffLine], language: String, to textView: NSTextView) {
            textView.textStorage?.setAttributedString(Self.buildAttributedString(lines: lines, language: language))
            lastLines = lines
            lastLanguage = language
            lastFingerprint = fingerprint(of: lines, language: language)
        }

        private func fingerprint(of lines: [DiffLine], language: String) -> Int {
            var hasher = Hasher()
            hasher.combine(language)
            hasher.combine(lines.count)
            if let first = lines.first {
                hasher.combine(first.text)
                hasher.combine(first.kind)
            }
            if let last = lines.last, lines.count > 1 {
                hasher.combine(last.text)
                hasher.combine(last.kind)
            }
            return hasher.finalize()
        }

        private static func buildAttributedString(lines: [DiffLine], language: String) -> NSAttributedString {
            let fontSize: CGFloat = 12
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let gutterColor = NSColor(ClaudeTheme.textTertiary).withAlphaComponent(0.6)
            let gutterDigits = max(String(lines.count).count, 2)
            let blankPrefix = String(repeating: " ", count: gutterDigits) + "  "

            let addedBg = NSColor(ClaudeTheme.statusSuccess).withAlphaComponent(0.14)
            let removedBg = NSColor(ClaudeTheme.statusError).withAlphaComponent(0.14)

            let result = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                let prefix: String
                if line.kind == .meta {
                    prefix = blankPrefix
                } else {
                    let n = String(index + 1)
                    prefix = String(repeating: " ", count: gutterDigits - n.count) + n + "  "
                }

                let rowBg: NSColor? = {
                    switch line.kind {
                    case .added:   return addedBg
                    case .removed: return removedBg
                    default:       return nil
                    }
                }()

                var gutterAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: gutterColor,
                ]
                if let bg = rowBg { gutterAttrs[.backgroundColor] = bg }
                result.append(NSAttributedString(string: prefix, attributes: gutterAttrs))

                let body = buildLineBody(line: line, language: language, font: font, fontSize: fontSize, rowBg: rowBg)
                result.append(body)

                var newlineAttrs: [NSAttributedString.Key: Any] = [.font: font]
                if let bg = rowBg { newlineAttrs[.backgroundColor] = bg }
                result.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
            }
            return result
        }

        private static func buildLineBody(
            line: DiffLine,
            language: String,
            font: NSFont,
            fontSize: CGFloat,
            rowBg: NSColor?
        ) -> NSAttributedString {
            switch line.kind {
            case .hunk, .meta:
                let text = line.text.isEmpty ? " " : line.text
                return NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(line.kind.foregroundColor),
                ])
            case .added, .removed, .context:
                let (marker, content) = splitDiffMarker(line: line)
                let out = NSMutableAttributedString()

                if !marker.isEmpty {
                    let markerColor: NSColor
                    switch line.kind {
                    case .added:   markerColor = NSColor(ClaudeTheme.statusSuccess)
                    case .removed: markerColor = NSColor(ClaudeTheme.statusError)
                    default:       markerColor = NSColor(ClaudeTheme.textTertiary)
                    }
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: markerColor,
                    ]
                    if let bg = rowBg { attrs[.backgroundColor] = bg }
                    out.append(NSAttributedString(string: marker, attributes: attrs))
                }

                let bodyText = content.isEmpty ? " " : content
                let highlighted: NSMutableAttributedString
                if !language.isEmpty, !content.isEmpty {
                    highlighted = NSMutableAttributedString(
                        attributedString: SyntaxHighlighter.highlightNS(bodyText, language: language, fontSize: fontSize)
                    )
                } else {
                    highlighted = NSMutableAttributedString(string: bodyText, attributes: [
                        .font: font,
                        .foregroundColor: NSColor(ClaudeTheme.textPrimary),
                    ])
                }
                if let bg = rowBg, highlighted.length > 0 {
                    highlighted.addAttribute(
                        .backgroundColor,
                        value: bg,
                        range: NSRange(location: 0, length: highlighted.length)
                    )
                }
                out.append(highlighted)
                return out
            }
        }

        private static func splitDiffMarker(line: DiffLine) -> (marker: String, content: String) {
            let raw = line.text
            switch line.kind {
            case .added where raw.hasPrefix("+"):
                return ("+", String(raw.dropFirst()))
            case .removed where raw.hasPrefix("-"):
                return ("-", String(raw.dropFirst()))
            case .context where raw.hasPrefix(" "):
                return (" ", String(raw.dropFirst()))
            default:
                return ("", raw)
            }
        }
    }
}
