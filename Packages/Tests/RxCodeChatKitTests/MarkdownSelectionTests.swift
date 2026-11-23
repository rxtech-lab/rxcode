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

    @Test("Review annotations use the exact source occurrence across Markdown runs")
    func annotatedMarkdown() throws {
        _ = NSApplication.shared
        let markdown = "## Draft\n\n- 👩‍💻 First **save** then `save` via [docs](https://example.org).\n\n```swift\nlet saved = true\n```"
        let source = markdown as NSString
        let first = source.range(of: "**save** then")
        let code = source.range(of: "saved = true")
        let deleted = NSRange(location: source.range(of: "via").location, length: 0)
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.display(text: markdown, baseURL: nil, style: .rxCodeChat, markedRanges: [first, code, deleted])
        _ = view.measure(width: 400, expandsHorizontally: true)
        let storage = try #require(view.textStorage)
        let text = storage.string as NSString
        try #require(text.contains("First save then save ⌫via docs."))
        let bold = text.range(of: "save then")
        #expect(storage.attribute(.markdownAnnotation, at: bold.location, effectiveRange: nil) as? Int == 0)
        #expect(storage.attribute(.underlineStyle, at: NSMaxRange(bold) - 1, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let unmarked = text.range(of: "save ⌫")
        #expect(storage.attribute(.markdownAnnotation, at: unmarked.location, effectiveRange: nil) == nil)
        let codeLocation = text.range(of: "saved = true").location
        #expect(storage.attribute(.markdownAnnotation, at: codeLocation, effectiveRange: nil) as? Int == 1)
        let docs = try #require(storage.attribute(.link, at: text.range(of: "docs").location, effectiveRange: nil) as? URL)
        #expect(docs.absoluteString == "https://example.org")

        var opened: Int?
        view.openAnnotation = { index, rect in if !rect.isEmpty { opened = index } }
        let marker = text.range(of: "⌫").location
        let link = try #require(storage.attribute(.link, at: marker, effectiveRange: nil))
        #expect(view.textView(view, clickedOnLink: link, at: marker))
        #expect(opened == 2)
    }

    @Test("The strike advances over the original passage and resets on a revision")
    func animatedStrike() throws {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        let passage = "Write atomically."
        view.display(text: passage, baseURL: nil, style: .rxCodeChat,
                     markedRanges: [NSRange(location: 6, length: 10)], striking: true)
        let layout = try #require(view.layoutManager)
        view.setStrikeProgress(0.5)
        #expect(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 10, effectiveRange: nil) != nil)
        #expect(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 11, effectiveRange: nil) == nil)
        view.setStrikeProgress(1)
        #expect(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 15, effectiveRange: nil) != nil)
        view.display(text: "New", baseURL: nil, style: .rxCodeChat)
        #expect(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 1, effectiveRange: nil) == nil)
    }

}
#endif
