import SwiftUI
import RxCodeChatKit
import RxCodeCore

struct MarkdownPreviewView: View {
    let content: String
    let baseURL: URL?

    init(content: String, baseURL: URL? = nil) {
        self.content = content
        self.baseURL = baseURL
    }

    var body: some View {
        ScrollView {
            MarkdownContentView(text: content, baseURL: baseURL)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .background(ClaudeTheme.background)
    }
}
