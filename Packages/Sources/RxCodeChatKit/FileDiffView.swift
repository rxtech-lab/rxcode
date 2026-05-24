import SwiftUI
#if os(macOS)
import AppKit
import RxCodeCore

public struct FileDiffView: View {
    public let filePath: String
    public let fileName: String
    public let editHunks: [PreviewFile.EditHunk]
    public let gitDiffMode: PreviewFile.GitDiffMode?
    public let showFullFileDiff: Bool
    /// Optional pre-edit snapshot. When provided alongside `showFullFileDiff`,
    /// the view diffs this snapshot against the current on-disk content
    /// directly — bypassing hunk reverse-application. This gives an exact diff
    /// even when other agents have concurrently modified the file.
    public let originalContent: String?
    @Environment(WindowState.self) private var windowState
    @State private var diffLines: [DiffLine] = []
    @State private var isLoading = true
    @State private var isCopied = false

    public init(
        filePath: String,
        fileName: String,
        editHunks: [PreviewFile.EditHunk] = [],
        gitDiffMode: PreviewFile.GitDiffMode? = nil,
        showFullFileDiff: Bool = false,
        originalContent: String? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.editHunks = editHunks
        self.gitDiffMode = gitDiffMode
        self.showFullFileDiff = showFullFileDiff
        self.originalContent = originalContent
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

        // Preferred path when both showFullFileDiff and an originalContent
        // snapshot are available: diff the snapshot directly against the
        // current file contents. This is exact under concurrent edits — no
        // hunk reverse-application, no orphan "unmatched change" headers.
        if showFullFileDiff, let original = originalContent {
            let path = filePath
            diffLines = await Task.detached(priority: .userInitiated) {
                let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                return FileDiffView.buildSnapshotDiffLines(original: original, current: current)
            }.value
            return
        }

        if !editHunks.isEmpty {
            let hunks = editHunks
            let path = filePath
            if showFullFileDiff,
               let fullFileLines = await Task.detached(priority: .userInitiated, operation: { () -> [DiffLine]? in
                   guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                       return nil
                   }
                   return FileDiffView.buildFullFileEditDiffLines(currentContent: contents, hunks: hunks)
               }).value {
                diffLines = fullFileLines
                return
            }

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
        var oldLine = 0
        var newLine = 0
        var result: [DiffLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) {
                    oldLine = o
                    newLine = n
                }
                result.append(DiffLine(text: line, kind: .hunk))
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                result.append(DiffLine(text: line, kind: .meta))
            } else if line.hasPrefix("+") {
                result.append(DiffLine(text: line, kind: .added, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                result.append(DiffLine(text: line, kind: .removed, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else {
                result.append(DiffLine(text: line, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return result
    }

    /// Parses a `@@ -oldStart,oldCount +newStart,newCount @@` header and
    /// returns the starting line numbers (1-based). Returns nil for malformed
    /// headers.
    private nonisolated static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // Expected shape: `@@ -<old>[,<count>] +<new>[,<count>] @@ <context>`
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@") != nil,
              scanner.scanString(" -") != nil,
              let oldStart = scanner.scanInt() else { return nil }
        _ = scanner.scanString(",")
        _ = scanner.scanInt()
        guard scanner.scanString(" +") != nil,
              let newStart = scanner.scanInt() else { return nil }
        return (oldStart, newStart)
    }

    nonisolated static func buildFullFileEditDiffLines(
        currentContent: String,
        hunks: [PreviewFile.EditHunk]
    ) -> [DiffLine] {
        return buildCurrentContentDiffLines(currentContent: currentContent, hunks: hunks)
    }

    /// Build a unified diff between two full-file snapshots. Used when a
    /// pre-edit snapshot is available (captured at tool_use time), so we can
    /// render an exact diff without ever reverse-applying hunks.
    nonisolated static func buildSnapshotDiffLines(
        original: String,
        current: String
    ) -> [DiffLine] {
        let originalLines = contentLines(original)
        let currentLines = contentLines(current)
        return computeUnifiedDiffLines(old: originalLines, new: currentLines)
    }

    /// Build a unified diff that shows the full current file with the hunks
    /// rendered inline on top of it. Works by reverse-applying each hunk
    /// (newString → oldString) against the current content to reconstruct the
    /// pre-edit state, then running a proper line diff between the pre-edit
    /// and current lines. Hunks that can't be reverse-applied — pure
    /// deletions (empty newString) or hunks whose newString no longer appears
    /// in the file — become "orphan" hunks rendered at the top with a header,
    /// so a deleted line is still visible even though its exact original
    /// position can't be recovered.
    private nonisolated static func buildCurrentContentDiffLines(
        currentContent: String,
        hunks: [PreviewFile.EditHunk]
    ) -> [DiffLine] {
        let currentLines = contentLines(currentContent)
        guard !currentLines.isEmpty else {
            return buildEditDiffLines(from: hunks)
        }

        var reconstructed = currentContent
        var orphans: [PreviewFile.EditHunk] = []

        for hunk in hunks.reversed() {
            if hunk.newString.isEmpty {
                if !hunk.oldString.isEmpty {
                    orphans.insert(hunk, at: 0)
                }
                continue
            }
            if let range = reconstructed.range(of: hunk.newString) {
                reconstructed.replaceSubrange(range, with: hunk.oldString)
            } else if !hunk.oldString.isEmpty {
                orphans.insert(hunk, at: 0)
            }
        }

        let preEditLines = contentLines(reconstructed)
        let unifiedLines = computeUnifiedDiffLines(old: preEditLines, new: currentLines)

        guard !orphans.isEmpty else { return unifiedLines }

        var result: [DiffLine] = []
        for (idx, orphan) in orphans.enumerated() {
            let header = orphans.count > 1
                ? "@@ unmatched change \(idx + 1)/\(orphans.count) @@"
                : "@@ unmatched change @@"
            result.append(DiffLine(text: header, kind: .hunk))
            for line in contentLines(orphan.oldString) {
                result.append(DiffLine(text: "-\(line)", kind: .removed))
            }
            for line in contentLines(orphan.newString) {
                result.append(DiffLine(text: "+\(line)", kind: .added))
            }
        }
        result.append(contentsOf: unifiedLines)
        return result
    }

    private nonisolated static func computeUnifiedDiffLines(
        old: [String],
        new: [String]
    ) -> [DiffLine] {
        let diff = new.difference(from: old)
        var removalIndices = Set<Int>()
        var insertionElements: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removalIndices.insert(offset)
            case .insert(let offset, let element, _):
                insertionElements[offset] = element
            }
        }

        var lines: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < old.count || newIdx < new.count {
            if oldIdx < old.count, removalIndices.contains(oldIdx) {
                lines.append(DiffLine(
                    text: "-\(old[oldIdx])",
                    kind: .removed,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: nil
                ))
                oldIdx += 1
            } else if newIdx < new.count, let added = insertionElements[newIdx] {
                lines.append(DiffLine(
                    text: "+\(added)",
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: newIdx + 1
                ))
                newIdx += 1
            } else if oldIdx < old.count, newIdx < new.count {
                lines.append(DiffLine(
                    text: " \(new[newIdx])",
                    kind: .context,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: newIdx + 1
                ))
                oldIdx += 1
                newIdx += 1
            } else if oldIdx < old.count {
                lines.append(DiffLine(
                    text: " \(old[oldIdx])",
                    kind: .context,
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: nil
                ))
                oldIdx += 1
            } else if newIdx < new.count {
                lines.append(DiffLine(
                    text: " \(new[newIdx])",
                    kind: .context,
                    oldLineNumber: nil,
                    newLineNumber: newIdx + 1
                ))
                newIdx += 1
            }
        }

        return lines
    }

    private nonisolated static func contentLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
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
    /// 1-based line number in the pre-edit file (left gutter). Nil for added,
    /// hunk, meta, or orphan rows that have no pre-edit position.
    let oldLineNumber: Int?
    /// 1-based line number in the current file (right gutter). Nil for removed,
    /// hunk, meta, or orphan rows that have no post-edit position.
    let newLineNumber: Int?

    nonisolated init(text: String, kind: Kind, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.text = text
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
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

            // GitHub-style two-column gutter: left = pre-edit line number,
            // right = post-edit line number. When one side is entirely empty
            // (e.g. a Write that created the file from nothing — every row is
            // pure addition), collapse to a single column so we don't waste
            // gutter width on a permanently blank lane.
            let maxOld = lines.compactMap(\.oldLineNumber).max() ?? 0
            let maxNew = lines.compactMap(\.newLineNumber).max() ?? 0
            let showOld = maxOld > 0
            let showNew = maxNew > 0
            let oldDigits = max(String(maxOld).count, 2)
            let newDigits = max(String(maxNew).count, 2)
            let oldBlank = String(repeating: " ", count: oldDigits)
            let newBlank = String(repeating: " ", count: newDigits)

            let addedBg = NSColor(ClaudeTheme.statusSuccess).withAlphaComponent(0.14)
            let removedBg = NSColor(ClaudeTheme.statusError).withAlphaComponent(0.14)

            func pad(_ n: Int?, width: Int, blank: String) -> String {
                guard let n else { return blank }
                let s = String(n)
                if s.count >= width { return s }
                return String(repeating: " ", count: width - s.count) + s
            }

            func gutterPrefix(for line: DiffLine) -> String {
                let isHeader = line.kind == .meta || line.kind == .hunk
                switch (showOld, showNew) {
                case (true, true):
                    if isHeader { return oldBlank + " " + newBlank + " " }
                    return pad(line.oldLineNumber, width: oldDigits, blank: oldBlank)
                        + " "
                        + pad(line.newLineNumber, width: newDigits, blank: newBlank)
                        + " "
                case (true, false):
                    if isHeader { return oldBlank + " " }
                    return pad(line.oldLineNumber, width: oldDigits, blank: oldBlank) + " "
                case (false, true):
                    if isHeader { return newBlank + " " }
                    return pad(line.newLineNumber, width: newDigits, blank: newBlank) + " "
                case (false, false):
                    return ""
                }
            }

            let result = NSMutableAttributedString()
            for line in lines {
                let prefix = gutterPrefix(for: line)

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
#endif
