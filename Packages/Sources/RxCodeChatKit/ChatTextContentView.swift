import SwiftUI
import RxCodeCore

/// Renders inline chat text — plain strings, pre-built attributed strings, or
/// inline-only markdown — using native SwiftUI `Text`.
public struct ChatTextContentView: View {
    enum Content {
        case plain(String)
        case attributed(AttributedString)
    }

    let content: Content
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    var color: Color
    var lineSpacing: CGFloat
    var maximumNumberOfLines: Int?
    var openURL: ((URL) -> Bool)?

    public init(
        _ text: String,
        size: CGFloat = ClaudeTheme.messageSize(14),
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color = ClaudeTheme.textPrimary,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int? = nil,
        openURL: ((URL) -> Bool)? = nil
    ) {
        self.content = .plain(text)
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.openURL = openURL
    }

    public init(
        attributed content: AttributedString,
        size: CGFloat = ClaudeTheme.messageSize(14),
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color = ClaudeTheme.textPrimary,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int? = nil,
        openURL: ((URL) -> Bool)? = nil
    ) {
        self.content = .attributed(content)
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.openURL = openURL
    }

    public init(
        markdown text: String,
        size: CGFloat = ClaudeTheme.messageSize(14),
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color = ClaudeTheme.textPrimary,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int? = nil,
        openURL: ((URL) -> Bool)? = nil
    ) {
        self.content = .attributed(Self.markdownAttributedString(text))
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.openURL = openURL
    }

    public var body: some View {
        let text = {
            switch content {
            case .plain(let value):
                return Text(value)
            case .attributed(let value):
                return Text(value)
            }
        }()

        text
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(color)
            .tint(ClaudeTheme.accent)
            .lineSpacing(lineSpacing)
            .lineLimit(maximumNumberOfLines)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let openURL else { return .systemAction }
                return openURL(url) ? .handled : .systemAction
            })
    }

    private static func markdownAttributedString(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
