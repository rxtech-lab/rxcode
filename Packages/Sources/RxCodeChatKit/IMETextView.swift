#if os(macOS)
@_exported import RxAttachmentField
import SwiftUI

public extension View {
    func rxCodeAttachmentPreviews() -> some View {
        environment(\.attachmentMarkdownPreview, { text, url in
            AnyView(ScrollView {
                MarkdownContentView(text: text, baseURL: url.deletingLastPathComponent())
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            })
        })
    }
}
#endif
