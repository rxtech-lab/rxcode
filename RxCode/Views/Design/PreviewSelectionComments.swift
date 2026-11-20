import AppKit
import PDFKit
import RxCodeCore
import SwiftUI
import VisionKit
import WebKit

struct PreviewExcerpt: Identifiable {
    let id = UUID()
    let text: String
    let location: String?
    var highlight: PreviewSelectionHighlight?

    init?(_ text: String?, location: String? = nil) {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return nil }
        self.text = text
        self.location = location
    }

    /// Read the selection from the renderer under the pointer.
    static func read(in hit: NSView, at screenPoint: CGPoint, keepingSelection: Bool = false,
                     requireSelectionAtPoint: Bool = false) async -> Self? {
        let windowPoint = hit.window?.convertPoint(fromScreen: screenPoint) ?? .zero
        for view in sequence(first: hit, next: { $0.superview }) {
            if view is NSRulerView { return nil }
            if let source = view as? SourcePreviewTextView {
                if requireSelectionAtPoint, !source.containsSelectedText(at: source.convert(windowPoint, from: nil)) { return nil }
                var excerpt = source.selectedExcerpt
                if keepingSelection { excerpt?.highlight = .text(in: source) }
                return excerpt
            }
            if let liveText = view as? ImageAnalysisOverlayView {
                if requireSelectionAtPoint, !liveText.hasText(at: liveText.convert(windowPoint, from: nil)) { return nil }
                var excerpt = Self(liveText.selectedText)
                if keepingSelection { excerpt?.highlight = .liveText(in: liveText) }
                return excerpt
            }
            if let pdf = view as? PDFView, let document = pdf.document {
                guard document.allowsCopying, let selection = pdf.currentSelection else { return nil }
                if requireSelectionAtPoint {
                    let point = pdf.convert(windowPoint, from: nil)
                    guard let page = pdf.page(for: point, nearest: false) else { return nil }
                    let onPage = pdf.convert(point, to: page)
                    guard selection.selectionsByLine().contains(where: { $0.bounds(for: page).contains(onPage) }) else { return nil }
                }
                let page = selection.pages.first.map { "Page \(document.index(for: $0) + 1)" }
                var excerpt = Self(selection.string, location: page)
                if keepingSelection { excerpt?.highlight = .pdf(selection, in: pdf) }
                return excerpt
            }
            if let web = view as? WKWebView {
                // The document's own scripts stay disabled in local HTML previews.
                let key = keepingSelection ? "rxcode-comment-" + UUID().uuidString : ""
                let point = web.convert(windowPoint, from: nil)
                let y = web.isFlipped ? point.y - web.bounds.minY : web.bounds.maxY - point.y
                let text = try? await web.callAsyncJavaScript("""
                    if (!document.hidden) await new Promise(resolve => {
                        requestAnimationFrame(resolve);
                        setTimeout(resolve, 80);
                    });
                    let doc = document;
                    const scale = window.innerWidth / Math.max(1, width);
                    let x = pointerX * scale, y = pointerY * scale;
                    while (doc.activeElement?.contentDocument) {
                        const frame = doc.activeElement, rect = frame.getBoundingClientRect();
                        x = (x - rect.left) * frame.offsetWidth / rect.width - frame.clientLeft;
                        y = (y - rect.top) * frame.offsetHeight / rect.height - frame.clientTop;
                        doc = frame.contentDocument;
                    }
                    if (doc.activeElement?.matches('input,textarea') || doc.activeElement?.isContentEditable) return '';
                    const selection = doc.getSelection();
                    const text = selection?.toString();
                    if (atPoint && selection?.rangeCount && ![...selection.getRangeAt(0).getClientRects()]
                        .some(r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom)) return '';
                    if (key && text?.trim() && selection.rangeCount) {
                        globalThis.rxcodeCommentRanges ??= new Map();
                        rxcodeCommentRanges.set(key, {range: selection.getRangeAt(0).cloneRange()});
                    }
                    return text || null;
                    """, arguments: ["key": key, "atPoint": requireSelectionAtPoint, "width": web.bounds.width,
                                     "pointerX": point.x - web.bounds.minX, "pointerY": y], in: nil, contentWorld: .defaultClient) as? String
                if let text {
                    var excerpt = Self(text)
                    if keepingSelection { excerpt?.highlight = .web(in: web, key: key) }
                    return excerpt
                }
                break
            }
        }

        // SwiftUI Markdown and native preview providers expose their highlighted
        // text through AppKit. Some providers implement only the Services API.
        let element = hit.accessibilityHitTest(screenPoint) as? NSAccessibilityProtocol
        if var excerpt = Self(element?.accessibilitySelectedText() ?? hit.accessibilitySelectedText()) {
            if keepingSelection { excerpt.highlight = .accessible(element ?? hit, in: hit) }
            return excerpt
        }
        guard let requestor = hit.validRequestor(forSendType: .string, returnType: nil) as? NSView,
              hit.isDescendant(of: requestor) || requestor.isDescendant(of: hit),
              let writer = requestor as? NSServicesMenuRequestor else { return nil }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard writer.writeSelection?(to: board, types: [.string]) == true else { return nil }
        var excerpt = Self(board.string(forType: .string))
        if keepingSelection { excerpt?.highlight = .accessible(element ?? requestor, in: hit) }
        return excerpt
    }
}

struct PreviewCommentPopover: View {
    let url: URL
    var browserTabID: UUID?
    var excerpt: PreviewExcerpt?
    var frame: PreviewCapture.Frame?
    var action: PreviewEditAction = .comment
    let close: () -> Void
    @Environment(AppState.self) private var app
    @Environment(WindowState.self) private var window

    var sourceContext: String {
        let source = url.isFileURL ? url.path : url.absoluteString
        var context = [browserTabID.map { "Browser tab \($0.uuidString)" }, source, excerpt?.location]
            .compactMap { $0 }.joined(separator: "\n")
        if let excerpt { context += "\n\nSelected text\n\(excerpt.text)" }
        return context
    }

    var body: some View {
        RefinementPopover(title: url.isFileURL ? url.lastPathComponent : url.host() ?? url.absoluteString,
                          action: action, excerpt: excerpt?.text, preview: frame?.image, previewCaption: frame?.caption) { comment in
            let context = sourceContext
            close()
            Task {
                await app.submitRefinement(comment, context: context, image: frame?.image,
                                           imageName: "\(url.lastPathComponent) preview.png", in: window)
            }
        }
    }
}

extension View {
    func previewSelectionComments(for url: URL?, browserTabID: UUID? = nil, capture: PreviewCapture? = nil) -> some View {
        modifier(PreviewSelectionComments(url: url, browserTabID: browserTabID, capture: capture))
    }
}

private struct PreviewSelectionComments: ViewModifier {
    let url: URL?
    let browserTabID: UUID?
    let capture: PreviewCapture?
    @Environment(AppState.self) private var app
    @Environment(WindowState.self) private var window
    @State private var presentation = PreviewCommentPresentation()

    func body(content: Content) -> some View {
        content
            .gesture(PreviewSelectionStart(began: presentation.dismiss))
            .overlay {
                if let url {
                    PreviewContextClick { surface, event in
                        guard let hit = surface.renderer(at: event) else { return }
                        chooseComment(for: url, in: hit, event: event)
                    }
                }
            }
            .onChange(of: url) { presentation.dismiss() }
            .onChange(of: browserTabID) { presentation.dismiss() }
            .onDisappear { presentation.dismiss() }
    }

    private func chooseComment(for url: URL, in hit: NSView, event: NSEvent) {
        presentation.choose(in: hit, event: event, resolve: { accepted in
            if !accepted { hit.rightMouseDown(with: event) }
        }) { action, excerpt, close in
            let frame = await capture?.snapshot(for: url)
            return PreviewCommentPopover(url: url, browserTabID: browserTabID, excerpt: excerpt, frame: frame, action: action, close: close)
                .environment(app).environment(window)
        }
    }
}

/// One selection owns its menu, editor and highlight, including when the preview changes mid-lookup.
@MainActor
final class PreviewCommentPresentation: NSObject, NSPopoverDelegate {
    private let trackMenu: (NSMenu, NSPoint, NSView) -> Void
    private var lookup: Task<Void, Never>?
    private var menu: NSMenu?
    private(set) var panel: NSPopover?
    private var excerpt: PreviewExcerpt?

    init(trackMenu: @escaping (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }) {
        self.trackMenu = trackMenu
    }

    func choose<Editor: View>(in hit: NSView, event: NSEvent, resolve: @escaping (Bool) -> Void,
                              editor: @escaping (PreviewEditAction, PreviewExcerpt, @escaping () -> Void) async -> Editor) {
        guard event.isPreviewContextClick else { resolve(false); return }
        dismiss()
        guard let window = hit.window else { resolve(false); return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        lookup = Task { @MainActor in
            let selection = await PreviewExcerpt.read(in: hit, at: point, keepingSelection: true,
                                                      requireSelectionAtPoint: true)
            guard !Task.isCancelled, hit.window === window else {
                selection?.highlight?.hide()
                return
            }
            guard let selection else { resolve(false); return }
            let original = hit.menu(for: event)
            let hasDeferredMenu = original?.items.isEmpty != false &&
                sequence(first: hit, next: { $0.superview }).contains { $0 is WKWebView || $0 is ImageAnalysisOverlayView }
            let actions = PreviewCommentMenu(text: selection.text, existing: original, offersRendererMenu: hasDeferredMenu)
            resolve(true)
            self.excerpt = selection
            selection.highlight?.show()
            menu = actions.menu
            trackMenu(actions.menu, hit.convert(event.locationInWindow, from: nil), hit)
            guard !Task.isCancelled else { return }
            menu = nil
            guard case .edit(let action) = actions.choice else {
                releaseHighlight()
                if actions.choice == .rendererMenu { hit.rightMouseDown(with: event) }
                return
            }
            let popover = NSPopover()
            let content = await editor(action, selection) { [weak popover] in popover?.performClose(nil) }
            guard !Task.isCancelled else { return }
            guard hit.window === window else { releaseHighlight(); return }
            panel = popover
            popover.delegate = self
            popover.showComment(content, at: point, in: window)
        }
    }

    func dismiss() {
        lookup?.cancel()
        lookup = nil
        menu?.cancelTrackingWithoutAnimation()
        menu = nil
        panel?.performClose(nil)
        panel = nil
        releaseHighlight()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === panel else { return }
        panel = nil
        releaseHighlight()
    }

    private func releaseHighlight() {
        excerpt?.highlight?.hide()
        excerpt = nil
    }
}

@MainActor
final class PreviewCommentMenu: NSObject {
    enum Choice: Equatable { case edit(PreviewEditAction), rendererMenu }
    let menu: NSMenu
    private(set) var choice: Choice?
    private let text: String?

    init(text: String? = nil, existing: NSMenu? = nil, offersRendererMenu: Bool = false) {
        self.text = text
        menu = existing?.copy() as? NSMenu ?? NSMenu()
        super.init()
        if menu.items.isEmpty, text != nil {
            let copy = menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copyExcerpt), keyEquivalent: "c")
            copy.target = self
        }
        if offersRendererMenu {
            // WebKit and Live Text build their own contextual commands after receiving the click.
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "More Actions…"), action: #selector(openRendererMenu), keyEquivalent: "").target = self
        }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for (index, action) in PreviewEditAction.allCases.enumerated() {
            let item = menu.insertItem(withTitle: action.title, action: #selector(editSelection(_:)), keyEquivalent: "", at: index)
            item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            item.representedObject = action
            item.target = self
        }
    }

    @objc private func editSelection(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? PreviewEditAction { choice = .edit(action) }
    }
    @objc private func openRendererMenu() { choice = .rendererMenu }

    @objc private func copyExcerpt() {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension NSPopover {
    func showComment(_ editor: some View, at screenPoint: CGPoint, in host: NSWindow) {
        guard let root = host.contentView else { return }
        behavior = .transient
        contentViewController = NSHostingController(rootView: editor)
        let anchor = root.convert(host.convertPoint(fromScreen: screenPoint), from: nil)
        show(relativeTo: NSRect(origin: anchor, size: NSSize(width: 1, height: 1)), of: root, preferredEdge: .minY)
    }
}

/// A new primary press cancels any pending context lookup before the renderer changes its selection.
private struct PreviewSelectionStart: NSGestureRecognizerRepresentable {
    let began: () -> Void

    func makeNSGestureRecognizer(context: Context) -> Observer {
        let recognizer = Observer()
        updateNSGestureRecognizer(recognizer, context: context)
        return recognizer
    }

    func updateNSGestureRecognizer(_ recognizer: Observer, context: Context) {
        recognizer.began = began
    }

    final class Observer: NSGestureRecognizer {
        var began: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if !event.modifierFlags.contains(.control) { began?() }
            state = .failed
        }

        override func canPrevent(_ other: NSGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: NSGestureRecognizer) -> Bool { false }
    }
}

private extension NSEvent {
    var isPreviewContextClick: Bool {
        type == .rightMouseDown || (type == .leftMouseDown && modifierFlags.contains(.control))
    }

    var previewHit: NSView? {
        guard let root = window?.contentView else { return nil }
        return root.hitTest(root.superview?.convert(locationInWindow, from: nil) ?? locationInWindow)
    }
}

/// Only secondary and Control-clicks hit this surface. Native text selection receives ordinary pointer events.
struct PreviewContextClick: NSViewRepresentable {
    let perform: (Surface, NSEvent) -> Void

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: Surface, context: Context) { view.perform = perform }

    final class Surface: NSView {
        var perform: ((Surface, NSEvent) -> Void)?
        private var findingRenderer = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !findingRenderer, let event = NSApp.currentEvent, event.window === window,
                  event.isPreviewContextClick,
                  visibleRect.contains(convert(point, from: superview)) else { return nil }
            return self
        }

        func renderer(at event: NSEvent) -> NSView? {
            findingRenderer = true
            defer { findingRenderer = false }
            let hit = event.previewHit
            return hit === self ? nil : hit
        }

        override func rightMouseDown(with event: NSEvent) { perform?(self, event) }
        override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }
        override func isAccessibilityElement() -> Bool { false }
    }
}
