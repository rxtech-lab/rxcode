import SwiftUI
import Foundation
import MarkdownUI
import RxCodeCore
import Textual
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Markdown Content View

/// Renders markdown text with the renderer selected in `Settings.swift`.
public struct MarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool
    let baseURL: URL?

    public init(
        text: String,
        showsTrailingCursor: Bool = false,
        isCursorVisible: Bool = true,
        baseURL: URL? = nil
    ) {
        self.text = text
        self.showsTrailingCursor = showsTrailingCursor
        self.isCursorVisible = isCursorVisible
        self.baseURL = baseURL
    }

    public var body: some View {
        switch RxCodeChatKitSettings.markdownRenderer {
        case .textual:
            TextualMarkdownContentView(
                text: text,
                showsTrailingCursor: showsTrailingCursor,
                isCursorVisible: isCursorVisible
            )
        case .markdownUI:
            MarkdownUIMarkdownContentView(
                text: text,
                showsTrailingCursor: showsTrailingCursor,
                isCursorVisible: isCursorVisible,
                baseURL: baseURL
            )
        }
    }
}

// MARK: - Textual Renderer

private struct TextualMarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool

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
            .textual.textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedMarkdown: String {
        let processed = preprocessMarkdown(text)
        if showsTrailingCursor && isCursorVisible {
            return processed + "\u{2009}\u{25CF}"
        }
        return processed
    }
}

// MARK: - MarkdownUI Renderer

private struct MarkdownUIMarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool
    let baseURL: URL?

    var body: some View {
        Markdown(renderedMarkdown, baseURL: baseURL, imageBaseURL: baseURL)
            .id(renderedMarkdown)
            .markdownTheme(.rxCodeChat)
            .markdownImageProvider(LocalFileImageProvider())
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.93))
                ForegroundColor(ClaudeTheme.textPrimary)
                BackgroundColor(ClaudeTheme.surfaceTertiary)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                MarkdownUICodeBlock(
                    language: configuration.language,
                    content: configuration.content
                ) {
                    configuration.label
                }
            }
            .tint(ClaudeTheme.accent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedMarkdown: String {
        let processed = preprocessMarkdown(text)
        if showsTrailingCursor && isCursorVisible {
            return processed + "\u{2009}\u{25CF}"
        }
        return processed
    }
}

private struct MarkdownUICodeBlock<Label: View>: View {
    let language: String?
    let content: String
    @ViewBuilder let label: () -> Label
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium, design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                Spacer()
                Button {
                    copyToClipboard(content, feedback: $isCopied)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ClaudeTheme.codeHeaderBackground)

            Rectangle()
                .fill(ClaudeTheme.border)
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                label()
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                        ForegroundColor(ClaudeTheme.textPrimary)
                        BackgroundColor(nil)
                    }
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
        .markdownMargin(top: .em(0.88), bottom: .em(0.4))
    }
}

private extension Theme {
    static let rxCodeChat = Theme.gitHub
        .text {
            FontSize(ClaudeTheme.messageSize(15))
            ForegroundColor(ClaudeTheme.textPrimary)
        }
        .link {
            ForegroundColor(ClaudeTheme.accent)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(.em(1.33))
                    FontWeight(.bold)
                    ForegroundColor(ClaudeTheme.textPrimary)
                }
                .markdownMargin(top: .em(1.2), bottom: .em(0.4))
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(.em(1.2))
                    FontWeight(.bold)
                    ForegroundColor(ClaudeTheme.textPrimary)
                }
                .markdownMargin(top: .em(1.2), bottom: .em(0.4))
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(.em(1.07))
                    FontWeight(.semibold)
                    ForegroundColor(ClaudeTheme.textPrimary)
                }
                .markdownMargin(top: .em(1.2), bottom: .em(0.4))
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle {
                    ForegroundColor(ClaudeTheme.textSecondary)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(ClaudeTheme.accent)
                        .frame(width: 3)
                }
                .markdownMargin(top: .em(0.8), bottom: .em(0.4))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: .em(0), bottom: .em(0.5))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15), bottom: .em(0.15))
        }
}

// MARK: - Markdown Preprocessing

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
            lines.append(autoLinkURLs(sanitizeMarkdownLinkURLs(convertHTMLImages(line))))
        }
    }
    return lines.joined(separator: "\n")
}

/// Rewrites HTML `<img src="..." alt="...">` tags into markdown image syntax so
/// MarkdownUI renders them instead of treating them as raw HTML.
func convertHTMLImages(_ text: String) -> String {
    let pattern = #"<img\b([^>]*?)/?>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return text
    }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: range).reversed() {
        guard let fullRange = Range(match.range, in: result),
              let attrsRange = Range(match.range(at: 1), in: result) else { continue }
        let attrs = String(result[attrsRange])
        guard let src = htmlAttribute("src", in: attrs) else { continue }
        let alt = htmlAttribute("alt", in: attrs) ?? ""
        result.replaceSubrange(fullRange, with: "![\(alt)](\(src))")
    }
    return result
}

private func htmlAttribute(_ name: String, in attrs: String) -> String? {
    let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) else {
        return nil
    }
    for index in 1..<match.numberOfRanges {
        if let range = Range(match.range(at: index), in: attrs) {
            return String(attrs[range])
        }
    }
    return nil
}

// MARK: - Textual Styles

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

// MARK: - Local File Image Provider

/// Renders images from `file://` URLs by loading them via NSImage, and falls
/// back to MarkdownUI's default network image provider for remote URLs.
private struct LocalFileImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.isFileURL {
                LocalFileImage(url: url)
            } else {
                DefaultImageProvider.default.makeImage(url: url)
            }
        }
    }
}

private struct LocalFileImage: View {
    let url: URL

    var body: some View {
        if let loaded = LocalFileImage.load(url: url) {
            loaded.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: loaded.size.width)
        } else {
            Text("⚠︎ \(url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private struct Loaded {
        let image: Image
        let size: CGSize
    }

    private static func load(url: URL) -> Loaded? {
        #if canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Loaded(image: Image(nsImage: nsImage), size: nsImage.size)
        #elseif canImport(UIKit)
        guard let data = try? Data(contentsOf: url),
              let uiImage = UIImage(data: data) else { return nil }
        return Loaded(image: Image(uiImage: uiImage), size: uiImage.size)
        #else
        return nil
        #endif
    }
}

// MARK: - Markdown Link Helpers

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

func autoLinkURLs(_ text: String) -> String {
    let pattern = #"(?<!\]\()(?<!\()https?://[^\s\)<>\[\]`]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in regex.matches(in: text, range: range).reversed() {
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
