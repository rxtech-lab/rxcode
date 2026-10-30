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
    func pastePreservesDraft(action: String, includesImage: Bool) async throws {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        if includesImage { pasteboard.setData(png, forType: .png) }
        pasteboard.setString(includesImage ? "\n" : "first\nsecond", forType: .string)

        let state = WindowState()
        state.inputText = "Describe this"
        let bridge = ChatBridge()
        bridge.autoPreviewSettings.image = true
        let host = NSHostingView(rootView: InputBarView(
            windowState: state, chatBridge: bridge, accessory: EmptyView()
        ) { EmptyView() })
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let editor = try #require(findEditor(in: host))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.perform(NSSelectorFromString(action), with: nil)
        try await Task.sleep(for: .milliseconds(50))

        if includesImage {
            #expect(state.attachments.count == 1)
            #expect(state.attachments.first?.type == .image)
            #expect(state.inputText == "Describe this [Image1] ")
            #expect(!state.inputText.contains("\n"))
        } else {
            #expect(state.attachments.isEmpty)
            #expect(state.inputText == "Describe thisfirst\nsecond")
        }
    }

    private func findEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }
}
#endif
