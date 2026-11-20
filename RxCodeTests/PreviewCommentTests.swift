import PDFKit
import RxCodeCore
import SwiftUI
import WebKit
import XCTest
@testable import RxCode

@MainActor
final class PreviewCommentTests: XCTestCase {
    func testCommentAndRefineAreExplicitChoicesAlongsideNativeSelectionActions() throws {
        let original = NSMenu()
        original.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
        let actions = PreviewCommentMenu(text: "Two moons", existing: original)
        XCTAssertEqual(original.items.map(\.title), ["Look Up"])
        XCTAssertEqual(actions.menu.items.last?.title, "Look Up")
        XCTAssertNil(actions.choice)
        for action in PreviewEditAction.allCases {
            let item = try XCTUnwrap(actions.menu.item(withTitle: action.title))
            actions.menu.performActionForItem(at: actions.menu.index(of: item))
            XCTAssertEqual(actions.choice, .edit(action))
        }
        let deferred = PreviewCommentMenu(text: "Two moons", existing: nil, offersRendererMenu: true)
        XCTAssertNotNil(deferred.menu.item(withTitle: "Copy"))
        let more = try XCTUnwrap(deferred.menu.item(withTitle: "More Actions…"))
        deferred.menu.performActionForItem(at: deferred.menu.index(of: more))
        XCTAssertEqual(deferred.choice, .rendererMenu)
    }

    func testContextClicksKeepTheSourceHighlightedUntilTheEditorCloses() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 440, height: 130)
        let window = NSWindow(contentRect: bounds, styleMask: .titled, backing: .buffered, defer: false)
        let source = SourcePreviewTextView(frame: bounds)
        source.isEditable = false
        source.display(SourcePreviewContent(.init(string: "Blue lantern, silver lantern")))
        window.contentView = source
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let range = (source.string as NSString).range(of: "lantern", options: .backwards)
        source.setSelectedRange(range)
        let rect = source.firstRect(forCharacterRange: range, actualRange: nil)
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        func event(_ type: NSEvent.EventType, at location: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        var choice: PreviewEditAction?
        var menus = 0
        let presentation = PreviewCommentPresentation { menu, _, _ in
            menus += 1
            if let choice {
                let index = menu.indexOfItem(withTitle: choice.title)
                XCTAssertGreaterThanOrEqual(index, 0)
                if index >= 0 { menu.performActionForItem(at: index) }
            }
        }
        defer { presentation.dismiss() }
        func open(_ input: NSEvent) async -> Bool {
            var accepted: Bool?
            presentation.choose(in: source, event: input, resolve: { accepted = $0 }) { action, excerpt, _ in
                XCTAssertEqual(action, choice)
                XCTAssertEqual(excerpt.text, "lantern")
                return TextField("Comment", text: .constant("Draft"))
            }
            for _ in 0..<100 where accepted == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return accepted == true
        }
        for input in [try event(.leftMouseDown, at: point), try event(.leftMouseDragged, at: point),
                      try event(.leftMouseUp, at: point), try event(.leftMouseUp, at: point, flags: .shift)] {
            let accepted = await open(input)
            XCTAssertFalse(accepted)
            XCTAssertEqual(source.selectedRange(), range)
            XCTAssertNil(presentation.panel)
        }
        let outside = try event(.rightMouseDown, at: CGPoint(x: 2, y: point.y))
        let acceptedOutside = await open(outside)
        XCTAssertFalse(acceptedOutside)
        XCTAssertEqual(menus, 0)
        let rightClick = try event(.rightMouseDown, at: point)
        let accepted = await open(rightClick)
        XCTAssertTrue(accepted)
        XCTAssertNil(presentation.panel)
        XCTAssertNil(source.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))

        for (action, input) in [(PreviewEditAction.comment, rightClick), (.refine, try event(.leftMouseDown, at: point, flags: .control))] {
            choice = action
            let accepted = await open(input)
            XCTAssertTrue(accepted)
            let panel = try XCTUnwrap(presentation.panel)
            XCTAssertTrue(panel.isShown)
            XCTAssertEqual(source.selectedRange(), range)
            XCTAssertNotNil(source.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
            panel.animates = false
            panel.performClose(nil)
            XCTAssertNil(source.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        }
        XCTAssertEqual(menus, 3)
    }

    func testRenderedSelectionStaysVisibleWhenOnlyItsAppearanceIsAvailable() throws {
        final class Passage: NSView {
            var selected = true
            override func draw(_ dirtyRect: NSRect) {
                NSColor.white.setFill()
                bounds.fill()
                if selected {
                    NSColor.blue.setFill()
                    NSRect(x: 10, y: 10, width: 32, height: 16).fill()
                }
            }
        }
        let frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        let host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let root = NSView(frame: frame)
        let passage = Passage(frame: frame)
        root.addSubview(passage)
        host.contentView = root
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: frame))
            root.cacheDisplay(in: frame, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let before = try pixels()
        let highlight = try XCTUnwrap(PreviewSelectionHighlight.accessible(passage, in: passage))
        highlight.show()
        passage.selected = false
        passage.needsDisplay = true
        XCTAssertEqual(try pixels(), before)
        XCTAssertTrue(root.hitTest(.init(x: 22, y: 18)) === passage)
        highlight.hide()
        XCTAssertNotEqual(try pixels(), before)
    }

    func testCommentEditorAnchorsAtTheSelectionInItsOwnWindow() throws {
        let host = NSWindow(contentRect: CGRect(x: 120, y: 160, width: 380, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView = NSHostingView(rootView: MarkdownPreviewView(content: "**Blue** lantern"))
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let root = try XCTUnwrap(host.contentView)
        let point = CGPoint(x: 35, y: 160)
        let screenPoint = host.convertPoint(toScreen: point)
        let panel = NSPopover()
        panel.animates = false
        defer { panel.performClose(nil) }
        let editor = PreviewCommentPopover(url: URL(fileURLWithPath: "/tmp/notes.md"), excerpt: PreviewExcerpt("Blue")) {}
        panel.showComment(editor.environment(AppState(startBackgroundServices: false)).environment(WindowState()),
                          at: screenPoint, in: host)
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.positioningRect, NSRect(origin: root.convert(point, from: nil), size: NSSize(width: 1, height: 1)))
    }

    func testSourceSelectionAndNativeCopyContainOnlyFileText() {
        let view = SourcePreviewTextView()
        let source = NSAttributedString(string: "let label = \"🌙\"\r\n\r\n    display(label)\n")
        let content = SourcePreviewContent(source)
        view.display(content)
        XCTAssertEqual(view.string, source.string)
        XCTAssertEqual(content.lineStarts.count, 4)
        XCTAssertEqual(content.lineStarts.last, source.length)
        let displayed = view.string as NSString
        let start = displayed.range(of: "🌙").location
        let end = NSMaxRange(displayed.range(of: "display"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(view.selectedExcerpt?.text, "🌙\"\r\n\r\n    display")
        XCTAssertEqual(view.selectedExcerpt?.location, "Lines 1–3")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        view.selectAll(nil)
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), source.string)
        XCTAssertEqual(view.selectedExcerpt?.text, source.string)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(view.selectedExcerpt)
    }

    func testGutterStaysBesideTheTextDuringSelectionAndScrolling() throws {
        let text = (1...100).map { "Source line \($0)" }.joined(separator: "\n")
        let host = NSHostingView(rootView: CodeTextRenderer(content: SourcePreviewContent(.init(string: text)))
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 140),
                              styleMask: .borderless, backing: .buffered, defer: false)
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func source(in view: NSView) -> SourcePreviewTextView? {
            (view as? SourcePreviewTextView) ?? view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        let textView = try XCTUnwrap(source(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let ruler = try XCTUnwrap(scroll.verticalRulerView)
        XCTAssertTrue(scroll.rulersVisible)
        let gutterPoint = ruler.convert(NSPoint(x: ruler.bounds.midX, y: ruler.bounds.midY), to: nil)
        let hit = host.hitTest(host.superview?.convert(gutterPoint, from: nil) ?? gutterPoint)
        XCTAssertTrue(hit?.isDescendant(of: ruler) == true)
        func gutterPixels() throws -> Data {
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let firstPage = try gutterPixels()
        textView.setSelectedRange((text as NSString).range(of: "Source line 1\nSource line 2"))
        XCTAssertEqual(try gutterPixels(), firstPage)
        textView.scrollRangeToVisible((text as NSString).range(of: "Source line 100"))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertNotEqual(try gutterPixels(), firstPage)
    }

    func testLocalHTMLSelectionUsesRenderedTextWithPageScriptsDisabled() async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 220), configuration: config)
        web.loadHTMLString("<title>Fixture</title><p>Two <b>🌙 moons</b></p><script>document.querySelector('p').remove()</script>",
                           baseURL: nil)
        for _ in 0..<100 where web.title != "Fixture" { try await Task.sleep(for: .milliseconds(30)) }
        _ = try await web.callAsyncJavaScript("""
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('p'));
            getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let selected = await PreviewExcerpt.read(in: web, at: .zero, keepingSelection: true)
        XCTAssertEqual(selected?.text, "Two 🌙 moons")
        selected?.highlight?.show()
        _ = try await web.callAsyncJavaScript("getSelection().removeAllRanges()", arguments: [:], in: nil, contentWorld: .defaultClient)
        let held = try await web.callAsyncJavaScript("return [...CSS.highlights.values()].flatMap(h => [...h].map(String))",
                                                     arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(held as? [String], ["Two 🌙 moons"])
        selected?.highlight?.hide()
        let remaining = try await web.callAsyncJavaScript("return CSS.highlights.size", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(remaining as? Int, 0)
        let empty = await PreviewExcerpt.read(in: web, at: .zero)
        XCTAssertNil(empty)
    }

    func testPDFQuoteIdentifiesTheSelectedPage() async throws {
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let drawing = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in ["First page", "Selected passage"] {
            drawing.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
            drawing.endPDFPage()
        }
        drawing.closePDF()
        let pdf = PDFView(frame: bounds)
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        pdf.document = document
        pdf.currentSelection = try XCTUnwrap(document.findString("Selected passage", withOptions: []).first)
        let searchResult = try XCTUnwrap(document.findString("First page", withOptions: []).first)
        pdf.highlightedSelections = [searchResult]
        let quote = await PreviewExcerpt.read(in: pdf, at: .zero, keepingSelection: true)
        XCTAssertEqual(quote?.text, "Selected passage")
        XCTAssertEqual(quote?.location, "Page 2")
        quote?.highlight?.show()
        XCTAssertEqual(pdf.highlightedSelections?.compactMap(\.string), ["First page", "Selected passage"])
        quote?.highlight?.hide()
        XCTAssertEqual(pdf.highlightedSelections?.compactMap(\.string), ["First page"])
    }

    func testVisualCommentQueuesTheCapturedFrameWithItsSourceInTheOriginatingThread() async throws {
        let app = AppState(startBackgroundServices: false)
        let window = WindowState()
        let thread = UUID().uuidString
        window.selectedProject = Project(name: "Preview", path: "/tmp/preview", gitHubRepo: nil)
        window.currentSessionId = thread
        var stream = SessionStreamState()
        stream.isStreaming = true
        app.sessionStates[thread] = stream
        defer { app.threadStore.clearQueue(sessionKey: thread) }

        let size = NSSize(width: 280, height: 160)
        let surface = NSImageView(frame: NSRect(origin: .zero, size: size))
        surface.image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let host = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = surface
        let capture = PreviewCapture()
        capture.view = surface
        let url = URL(fileURLWithPath: "/tmp/preview/slides.pptx")
        let frame = await capture.snapshot(for: url)
        let image = try XCTUnwrap(frame.image)
        surface.image = nil
        let expectedPNG = try XCTUnwrap(designPNG(image))
        let quote = PreviewExcerpt("Quarterly results")
        let comment = PreviewCommentPopover(url: url, excerpt: quote, frame: frame) {}
        await app.submitRefinement("Increase the title size", context: comment.sourceContext, image: image,
                                   imageName: "slides.pptx preview.png", in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        XCTAssertEqual(queued.text, "Increase the title size\n\n/tmp/preview/slides.pptx\n\nSelected text\nQuarterly results")
        XCTAssertEqual(queued.attachments.count, 1)
        XCTAssertEqual(queued.attachments.first?.type, .image)
        XCTAssertEqual(queued.attachments.first?.imageData, expectedPNG)
        XCTAssertEqual(queued.attachments.first?.name, "slides.pptx preview.png")
    }

    func testIdleChatSendsTheAttachedImagePathToTheBackend() async throws {
        let app = AppState(startBackgroundServices: false)
        let backend = MockAgentBackend(provider: .codex)
        app.agentBackendOverrides[.codex] = backend
        let window = WindowState()
        window.selectedProject = Project(name: "Preview", path: FileManager.default.temporaryDirectory.path)
        window.sessionAgentProvider = .codex
        window.sessionModel = "gpt-5"
        let image = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        await app.submitRefinement("Review this frame", context: "/tmp/clip.mp4", image: image,
                                   imageName: "clip.mp4 preview.png", in: window)
        let path = try XCTUnwrap(app.messages(in: window).last(where: { $0.role == .user })?.attachmentPaths.first?.path)
        XCTAssertFalse(path.isEmpty)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), designPNG(image))
        for _ in 0..<100 where await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        let requests = await backend.receivedRequests
        let prompt = try XCTUnwrap(requests.first?.prompt)
        XCTAssertTrue(prompt.contains("[Attached image: \(path)]"))
        XCTAssertTrue(prompt.hasSuffix("Review this frame\n\n/tmp/clip.mp4"))
    }
}
