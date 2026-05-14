import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

/// ViewInspector tests for `MessageBubble`. These exercise the user-message rendering
/// path that surfaces inline `[Attached image: /path]` markers from CLI-history content.
///
/// MessageBubble depends on a `ChatBridge` via SwiftUI environment. Each test wraps the
/// bubble in a host view that injects a freshly-constructed bridge, then inspects the
/// resulting view tree.
@MainActor
@Suite("MessageBubble user-message rendering")
struct MessageBubbleTests {

    // MARK: - Helpers

    private struct Host<Content: View>: View {
        let bridge: ChatBridge
        @ViewBuilder var content: () -> Content
        var body: some View {
            content().environment(bridge)
        }
    }

    private func host(_ message: ChatMessage) -> Host<MessageBubble> {
        Host(bridge: ChatBridge()) { MessageBubble(message: message) }
    }

    private func writeTempImage() -> String {
        // Create a 1x1 PNG so NSImage(contentsOfFile:) succeeds in inlineAttachedImages.
        let path = NSTemporaryDirectory() + "rxcode-test-\(UUID().uuidString).png"
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return path
        }
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Tests

    @Test("Bubble inspects without crashing for a plain user message")
    func plainUserMessageInspectsCleanly() throws {
        let msg = ChatMessage(role: .user, content: "hello world")
        let view = host(msg)
        // Sanity: the inspection traversal succeeds (proves the body composes
        // with the test environment).
        #expect(throws: Never.self) {
            _ = try view.inspect()
        }
    }

    @Test("[Attached image] in content with no attachmentPaths renders an inline Image")
    func inlineAttachedImageFromContent() throws {
        let path = writeTempImage()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let content = "[Attached image: \(path)]\n\n[Image1] please review"
        let msg = ChatMessage(role: .user, content: content)
        let view = host(msg)
        let inspected = try view.inspect()

        // Expect at least one Image somewhere in the bubble — the inline thumbnail
        // produced by inlineAttachedImages(paths:).
        let images = inspected.findAll(ViewType.Image.self)
        #expect(!images.isEmpty, "expected an inline Image for the [Attached image: ...] marker")
    }

    @Test("Plain user message renders no Image views")
    func plainUserMessageHasNoImage() throws {
        let msg = ChatMessage(role: .user, content: "what is swift")
        let view = host(msg)
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        #expect(images.isEmpty, "expected no Image views for a plain text message")
    }

    @Test("[Attached image] marker is stripped from displayed text")
    func attachedImageMarkerStrippedFromText() throws {
        let path = writeTempImage()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let content = "[Attached image: \(path)]\n\n[Image1] please review"
        let msg = ChatMessage(role: .user, content: content)
        let view = host(msg)
        let inspected = try view.inspect()

        // Locate every Text view in the bubble and confirm none contain the
        // [Attached image: ...] marker. We don't pin to a specific structural
        // path because the AttributedString-driven Text is wrapped by helpers
        // (chipifiedAttributedString) that may shift the tree.
        let texts = inspected.findAll(ViewType.Text.self)
        for t in texts {
            let s = (try? t.string()) ?? ""
            #expect(!s.contains("[Attached image:"), "displayed Text leaked the attachment marker: \(s)")
        }
    }
}
