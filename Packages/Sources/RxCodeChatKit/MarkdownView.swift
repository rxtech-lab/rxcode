import SwiftUI
import RxCodeCore
import RxCodeMarkdown

extension MarkdownStyle {
    static var rxCodeChat: MarkdownStyle {
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
}

/// Renders markdown text through the pure SwiftUI markdown package while
/// preserving the historical ChatKit entry point.
public struct MarkdownContentView: View {
    let text: String
    let showsTrailingCursor: Bool
    let isCursorVisible: Bool
    let baseURL: URL?
    let fadeNewText: Bool
    let onOpenLink: MarkdownView.LinkHandler?

    public init(
        text: String,
        showsTrailingCursor: Bool = false,
        isCursorVisible: Bool = true,
        baseURL: URL? = nil,
        fadeNewText: Bool = false,
        onOpenLink: MarkdownView.LinkHandler? = nil
    ) {
        self.text = text
        self.showsTrailingCursor = showsTrailingCursor
        self.isCursorVisible = isCursorVisible
        self.baseURL = baseURL
        self.fadeNewText = fadeNewText
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        MarkdownView(
            text: text,
            showsTrailingCursor: showsTrailingCursor,
            isCursorVisible: isCursorVisible,
            baseURL: baseURL,
            style: .rxCodeChat,
            fadeNewText: fadeNewText,
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
