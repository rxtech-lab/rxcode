import SwiftUI
import Foundation
import RxCodeCore
import Textual

// MARK: - Markdown Content View

/// Renders markdown text — headings, lists, blockquotes, tables, and rich text —
/// using the Textual rendering engine (https://github.com/gonzalezreal/textual).
struct MarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool

    init(text: String, showsTrailingCursor: Bool = false, isCursorVisible: Bool = true) {
        self.text = text
        self.showsTrailingCursor = showsTrailingCursor
        self.isCursorVisible = isCursorVisible
    }

    var body: some View {
        StructuredText(markdown: renderedMarkdown)
            .id(renderedMarkdown)
            .font(.system(size: 15))
            .tint(ClaudeTheme.accent)
            .textual.inlineStyle(
                InlineStyle()
                    .code(
                        .monospaced,
                        .fontScale(0.93),
                        .backgroundColor(ClaudeTheme.surfaceTertiary),
                        .foregroundColor(ClaudeTheme.textPrimary)
                    )
            )
            .textual.headingStyle(RxCodeHeadingStyle())
            .textual.codeBlockStyle(RxCodeBlockStyle())
            // Keep Textual's text-selection overlay permanently disabled.
            // When enabled it installs a geometry-dependent
            // `onChange(of: AnyTextLayoutCollection)` that fires many times
            // per frame while the chat List scrolls, dropping frames and
            // making the scroll bumpy. Toggling it per scroll-phase is worse:
            // flipping selectability swaps Textual's view-tree branch and
            // rebuilds every visible markdown row. Whole-message and
            // per-code-block Copy buttons cover copying instead.
            .textual.textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The markdown actually passed to the renderer: bare URLs auto-linked and,
    /// while streaming, a trailing cursor glyph appended.
    private var renderedMarkdown: String {
        let processed = preprocessMarkdown(text)
        if showsTrailingCursor && isCursorVisible {
            return processed + "\u{2009}\u{25CF}"
        }
        return processed
    }
}

// MARK: - Markdown Preprocessing

/// Applies bare-URL auto-linking and link sanitization, skipping fenced code blocks
/// so URLs inside code samples are left untouched.
private func preprocessMarkdown(_ text: String) -> String {
    var lines: [String] = []
    var inFence = false
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inFence.toggle()
            lines.append(line)
        } else if inFence {
            lines.append(line)
        } else {
            lines.append(autoLinkURLs(sanitizeMarkdownLinkURLs(line)))
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - Heading Style

/// Heading style tuned to RxCode's chat typography (15pt body text).
private struct RxCodeHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.333, 1.2, 1.067, 1.0, 1.0, 1.0]
    private static let fontWeights: [Font.Weight] = [.bold, .bold, .semibold, .semibold, .medium, .medium]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .fontWeight(Self.fontWeights[level - 1])
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.4))
    }
}

// MARK: - Code Block Style

/// Code block style that keeps RxCode's chrome — language label and copy button —
/// while delegating syntax highlighting to Textual.
private struct RxCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        RxCodeBlockBody(configuration: configuration)
    }
}

private struct RxCodeBlockBody: View {
    let configuration: RxCodeBlockStyle.Configuration
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language = configuration.languageHint, !language.isEmpty {
                    Text(language)
                        .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                Spacer()
                copyButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ClaudeTheme.codeHeaderBackground)

            Rectangle()
                .fill(ClaudeTheme.border)
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .monospaced()
                    .textual.fontScale(0.882)
                    .textual.lineSpacing(.fontScaled(0.39))
                    .fixedSize()
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudeTheme.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
        .textual.blockSpacing(.fontScaled(top: 0.88, bottom: 0.4))
    }

    private var copyButton: some View {
        Button {
            configuration.codeBlock.copyToPasteboard()
            withAnimation { isCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { isCopied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                Text(isCopied ? String(localized: "Copied", bundle: .module) : String(localized: "Copy", bundle: .module))
                    .font(.caption2)
            }
            .foregroundStyle(isCopied ? ClaudeTheme.statusSuccess : ClaudeTheme.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Markdown Link Helpers

/// Removes incorrectly included characters (such as backticks) from URLs inside markdown links `[text](url)`
func sanitizeMarkdownLinkURLs(_ text: String) -> String {
    let pattern = #"\[([^\]]*)\]\(([^)]*`[^)]*)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: range).reversed() {
        guard let fullRange = Range(match.range, in: result),
              let labelRange = Range(match.range(at: 1), in: result),
              let urlRange = Range(match.range(at: 2), in: result) else { continue }
        let label = String(result[labelRange])
        let url = String(result[urlRange]).replacingOccurrences(of: "`", with: "")
        result.replaceSubrange(fullRange, with: "[\(label)](\(url))")
    }
    return result
}

/// Converts bare URLs not already inside a markdown link into `[url](url)` form
func autoLinkURLs(_ text: String) -> String {
    // Leave URLs already inside markdown links untouched
    // Pattern: match only bare URLs that are not in ](url) or [text](url) form
    let pattern = #"(?<!\]\()(?<!\()https?://[^\s\)<>\[\]`]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    // Substitute from back to front to prevent index shifting
    let matches = regex.matches(in: text, range: range).reversed()
    for match in matches {
        guard let swiftRange = Range(match.range, in: result) else { continue }
        let url = String(result[swiftRange])
        result.replaceSubrange(swiftRange, with: "[\(url)](\(url))")
    }
    return result
}

// MARK: - Previews

#Preview("Markdown") {
    ScrollView {
        MarkdownContentView(text: """
        # H1 Heading
        ## H2 Subheading
        ### H3 Section heading
        #### H4 Small heading

        This is a **markdown** test. `Inline code` is also supported.

        > This is a blockquote. Use it to emphasize important content.

        - List item 1
        - List item 2
        - **Bold** list item 3

        1. Ordered list
        2. Second item
        3. Third item

        ---

        | Item | Value |
        |------|-------|
        | Swift files | 381 |
        | Total lines | ~55,000 |
        | SwiftUI : UIKit ratio | 87% : 13% |

        ```swift
        func hello() {
            print("Hello, World!")
        }
        ```

        Regular text continues here.
        """)
        .padding()
    }
    .frame(width: 500, height: 600)
    .background(ClaudeTheme.background)
}
