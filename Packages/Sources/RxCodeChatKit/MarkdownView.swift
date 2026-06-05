import SwiftUI
import RxCodeCore
import RxCodeMarkdown

extension MarkdownStyle {
    public static var rxCodeChat: MarkdownStyle {
        MarkdownStyle(
            bodyFontSize: ClaudeTheme.messageSize(15),
            bodyColor: ClaudeTheme.textPrimary,
            secondaryColor: ClaudeTheme.textSecondary,
            accentColor: ClaudeTheme.accent,
            codeTextColor: ClaudeTheme.textPrimary,
            codeBackground: ClaudeTheme.codeBackground,
            codeHeaderBackground: ClaudeTheme.codeHeaderBackground,
            borderColor: ClaudeTheme.border,
            tableHeaderBackground: ClaudeTheme.surfaceSecondary,
            lineSpacing: 3,
            blockSpacing: 8,
            cornerRadius: ClaudeTheme.cornerRadiusSmall
        )
    }

    /// Markdown styling tuned for the accent-tinted user bubble: text and
    /// inline accents derive from `userBubbleText` so they stay legible on the
    /// dark bubble background instead of using the global primary/accent colors.
    public static var rxCodeChatUser: MarkdownStyle {
        let text = ClaudeTheme.userBubbleText
        return MarkdownStyle(
            bodyFontSize: ClaudeTheme.messageSize(14),
            bodyColor: text,
            secondaryColor: text.opacity(0.85),
            accentColor: text,
            codeTextColor: text,
            codeBackground: text.opacity(0.12),
            codeHeaderBackground: text.opacity(0.08),
            borderColor: text.opacity(0.22),
            tableHeaderBackground: text.opacity(0.1),
            lineSpacing: 3,
            blockSpacing: 8,
            cornerRadius: ClaudeTheme.cornerRadiusSmall
        )
    }
}

/// Renders markdown text through the pure SwiftUI markdown package while
/// preserving the historical ChatKit entry point.
public struct MarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool
    let baseURL: URL?
    let style: MarkdownStyle
    let fadeNewText: Bool
    let expandsHorizontally: Bool
    let onOpenLink: MarkdownView.LinkHandler?

    public init(
        text: String,
        showsTrailingCursor: Bool = false,
        isCursorVisible: Bool = true,
        baseURL: URL? = nil,
        style: MarkdownStyle = .rxCodeChat,
        fadeNewText: Bool = false,
        expandsHorizontally: Bool = true,
        onOpenLink: MarkdownView.LinkHandler? = nil
    ) {
        self.text = text
        self.showsTrailingCursor = showsTrailingCursor
        self.isCursorVisible = isCursorVisible
        self.baseURL = baseURL
        self.style = style
        self.fadeNewText = fadeNewText
        self.expandsHorizontally = expandsHorizontally
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        MarkdownView(
            text: text,
            showsTrailingCursor: showsTrailingCursor,
            isCursorVisible: isCursorVisible,
            baseURL: baseURL,
            style: style,
            fadeNewText: fadeNewText,
            expandsHorizontally: expandsHorizontally,
            onOpenLink: onOpenLink
        )
        .tint(ClaudeTheme.accent)
    }
}

#Preview("Chat Markdown") {
    ScrollView {
        MarkdownContentView(text: """
        # H1 Heading
        ## H2 Subheading

        This is a **markdown** test with `inline code` and [a link](https://example.com).

        > This is a blockquote.

        - List item 1
        - **Bold** list item 2

        | Item | Value |
        | --- | --- |
        | Swift files | Many |

        ```swift
        func hello() {
            print("Hello")
        }
        ```
        """)
        .padding()
    }
    .frame(width: 500, height: 600)
    .background(ClaudeTheme.background)
}
