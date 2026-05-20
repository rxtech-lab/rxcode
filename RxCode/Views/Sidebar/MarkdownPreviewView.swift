import SwiftUI
import RxCodeChatKit
import RxCodeCore

struct MarkdownPreviewView: View {
    let content: String

    var body: some View {
        ScrollView {
            MarkdownContentView(text: content)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .background(ClaudeTheme.background)
    }
}
