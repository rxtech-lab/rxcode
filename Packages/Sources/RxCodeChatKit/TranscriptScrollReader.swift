import SwiftUI

// A reader inside a hosted row finds its own transcript. Recycled rows share
// the same observation and the native list keeps its scrolling delegate.
#if os(macOS)
import AppKit

final class TranscriptScrollSurface: NSObject {
    private let onUserScroll: (Int, Bool) -> Void
    private weak var table: NSTableView?
    private var liveScrolling = false

    init(onUserScroll: @escaping (Int, Bool) -> Void) {
        self.onUserScroll = onUserScroll
    }

    func attach(to table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        self.table = table
        liveScrolling = false
        center.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(ended), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @objc private func started() { liveScrolling = true }
    @objc private func ended() { liveScrolling = false }

    @objc private func scrolled() {
        guard let table, let clip = table.enclosingScrollView?.contentView,
              table.bounds.height > clip.bounds.height,
              liveScrolling || hasWheelInput(in: clip) else { return }
        let visible = clip.documentVisibleRect
        let row = table.row(at: CGPoint(x: visible.midX, y: max(0, visible.minY)))
        onUserScroll(max(0, row), visible.maxY >= table.bounds.maxY - 1)
    }

    // Legacy wheels have no live-scroll phase. AppKit can retain the last
    // event while a stream grows, so only count recent input over this list.
    private func hasWheelInput(in clip: NSClipView) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .scrollWheel,
              event.window === clip.window,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.15 else { return false }
        return clip.bounds.contains(clip.convert(event.locationInWindow, from: nil))
    }

    /// Returns whether the destination reached the end of the transcript.
    func scroll(toRow row: Int) -> Bool {
        guard let table, (0..<table.numberOfRows).contains(row),
              let scroll = table.enclosingScrollView else { return false }
        let clip = scroll.contentView
        var target = clip.bounds
        target.origin.y = table.rect(ofRow: row).minY
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scroll.reflectScrolledClipView(clip)
        return clip.documentVisibleRect.maxY >= table.bounds.maxY - 1
    }
}

struct TranscriptScrollReader: NSViewRepresentable {
    let surface: TranscriptScrollSurface

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ view: Reader, context: Context) {
        guard view.surface !== surface else { return }
        view.surface = surface
        view.connect()
    }

    final class Reader: NSView {
        weak var surface: TranscriptScrollSurface?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func connect() {
            if let table = enclosingScrollView?.documentView as? NSTableView {
                surface?.attach(to: table)
            }
        }
    }
}
#else
import UIKit

final class TranscriptScrollSurface {
    private let onUserScroll: (Int, Bool) -> Void
    private weak var collection: UICollectionView?
    private var observation: NSKeyValueObservation?

    init(onUserScroll: @escaping (Int, Bool) -> Void) {
        self.onUserScroll = onUserScroll
    }

    func attach(to collection: UICollectionView) {
        guard self.collection !== collection else { return }
        self.collection = collection
        observation = collection.observe(\.contentOffset, options: [.new]) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard list.isTracking || list.isDragging || list.isDecelerating else { return }
                let top = list.contentOffset.y + list.adjustedContentInset.top
                let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
                guard end > -list.adjustedContentInset.top else { return }
                let point = CGPoint(x: list.bounds.midX, y: max(0, top + 0.5))
                let row = list.indexPathForItem(at: point)?.item ?? list.indexPathsForVisibleItems.min()?.item
                if let row { self?.onUserScroll(row, list.contentOffset.y >= end - 1) }
            }
        }
    }

    func scroll(toRow row: Int) -> Bool {
        guard let collection, collection.numberOfSections > 0,
              (0..<collection.numberOfItems(inSection: 0)).contains(row) else { return false }
        collection.scrollToItem(at: IndexPath(item: row, section: 0), at: .top, animated: false)
        let end = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
        return collection.contentOffset.y >= end - 1
    }
}

struct TranscriptScrollReader: UIViewRepresentable {
    let surface: TranscriptScrollSurface

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        guard view.surface !== surface else { return }
        view.surface = surface
        view.connect()
    }

    final class Reader: UIView {
        weak var surface: TranscriptScrollSurface?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        func connect() {
            var ancestor = superview
            while let view = ancestor {
                if let collection = view as? UICollectionView {
                    surface?.attach(to: collection)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
