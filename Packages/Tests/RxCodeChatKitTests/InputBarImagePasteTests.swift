#if os(macOS)
import AppKit
import SwiftUI
import Testing
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("Chat image paste", .serialized)
struct InputBarImagePasteTests {
    @Test("Paste actions attach images inline and preserve multiline text",
          arguments: ["paste:", "pasteAsPlainText:", "pasteAsRichText:"], [true, false])
    func pastePreservesDraft(action: String, includesImage: Bool) throws {
        _ = NSApplication.shared
        let state = WindowState()
        let replacesSelection = action == "pasteAsPlainText:"
        state.inputText = replacesSelection ? "Describe the selection now" : "Describe this"
        let bridge = ChatBridge()
        bridge.autoPreviewSettings.image = true
        let host = NSHostingView(rootView: InputBarView(
            windowState: state, chatBridge: bridge, accessory: EmptyView()
        ) { EmptyView() })
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(in: host))
        let content = editor.string as NSString
        editor.setSelectedRange(replacesSelection ? content.range(of: "the selection") : NSRange(location: content.length, length: 0))
        let item = NSPasteboardItem()
        if includesImage {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
            ))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try #require(item.setData(png, forType: .png))
        }
        try #require(item.setString(includesImage ? "\n" : "first\nsecond", forType: .string))

        let pasteboard = NSPasteboard.general
        let savedItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        try #require(pasteboard.writeObjects([item]))
        editor.perform(NSSelectorFromString(action), with: nil)

        if includesImage {
            #expect(state.attachments.count == 1)
            #expect(state.attachments.first?.type == .image)
            #expect(state.inputText == (replacesSelection ? "Describe [Image1] now" : "Describe this [Image1] "))
            #expect(!state.inputText.contains("\n"))
        } else {
            #expect(state.attachments.isEmpty)
            #expect(state.inputText == (replacesSelection ? "Describe first\nsecond now" : "Describe thisfirst\nsecond"))
        }
    }

    private func findEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }
}
#endif
