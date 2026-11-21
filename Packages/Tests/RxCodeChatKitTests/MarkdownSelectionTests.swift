#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import RxCodeChatKit

@MainActor
struct MarkdownSelectionTests {
    @Test("Markdown blocks share one native selection range")
    func selectAcrossBlocks() throws {
        _ = NSApplication.shared
        let baseURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let host = NSHostingView(rootView: ScrollView {
            MarkdownContentView(text: """
            # Heading

            First **bold** [paragraph](guide.md#example).

            - First item
            - Second item

            | Name | Value |
            | --- | --- |
            | Size | Large |

            ```swift
            let size = 2
            print(size)
            ```

            Last paragraph.
            """, baseURL: baseURL)
            .padding(16)
        })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let text = try #require(markdownView(in: host))
        let passage = "bold paragraph.\n-\tFirst item\n-\tSecond item\nName\nValue\nSize\nLarge\nswift\nlet size = 2\nprint(size)\nLast"
        let range = NSRange(try #require(text.string.range(of: passage)), in: text.string)
        text.setSelectedRange(range)
        #expect(text.accessibilitySelectedText() == passage)
        let linkRange = NSRange(try #require(text.string.range(of: "paragraph")), in: text.string)
        let link = text.textStorage?.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "file:///tmp/project/guide.md#example")
    }

    private func markdownView(in view: NSView) -> MarkdownTextView? {
        (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap { markdownView(in: $0) }.first
    }

}
#endif
