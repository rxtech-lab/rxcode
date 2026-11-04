#if DEBUG
import OSLog
import QuartzCore
import SwiftUI
import UIKit
import RxAgentUISupport

/// Aggregate hot-path timings instead of logging every streamed token or frame.
@MainActor
enum MobileChatPerformanceDiagnostics {
    private static let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "ChatPerformance")
    private struct Timing {
        var samples = 0
        var totalMS = 0.0
        var maxMS = 0.0
        var messages = 0
        var rows = 0
    }
    private static var timings: [String: Timing] = [:]
    private static var lastFlush = CACurrentMediaTime()

    static func recordTranscriptBodyUpdate() {
        PerformanceDiagnostics.increment("mobile.transcript.body_updates")
    }

    static func record(_ phase: String, since start: CFTimeInterval, messages: Int = 0, rows: Int = 0) {
        let elapsedMS = (CACurrentMediaTime() - start) * 1_000
        var timing = timings[phase, default: Timing()]
        timing.samples += 1
        timing.totalMS += elapsedMS
        timing.maxMS = max(timing.maxMS, elapsedMS)
        timing.messages = messages
        timing.rows = rows
        timings[phase] = timing
        guard CACurrentMediaTime() - lastFlush >= 2 else { return }
        for (phase, timing) in timings {
            logger.debug("PERFORMANCE: [Chat] phase=\(phase, privacy: .public) samples=\(timing.samples) avg_ms=\(timing.totalMS / Double(timing.samples)) max_ms=\(timing.maxMS) messages=\(timing.messages) rows=\(timing.rows)")
        }
        timings.removeAll(keepingCapacity: true)
        lastFlush = CACurrentMediaTime()
    }
}

/// Measures main-thread display callback gaps while the chat is onscreen.
/// These are approximate frame delays, not GPU render times or measured FPS.
struct MobileChatFrameMonitor: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let messageCount: Int
    let isStreaming: Bool

    func makeUIView(context: Context) -> FrameMonitorView { FrameMonitorView() }
    func updateUIView(_ uiView: FrameMonitorView, context: Context) {
        uiView.setContext(messageCount: messageCount, isStreaming: isStreaming)
        uiView.setActive(scenePhase == .active)
    }

    final class FrameMonitorView: UIView {
        private let target = DisplayLinkTarget()
        private var link: CADisplayLink?
        private var isActive = false

        func setContext(messageCount: Int, isStreaming: Bool) {
            target.messageCount = messageCount
            target.isStreaming = isStreaming
        }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            updateDisplayLink()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateDisplayLink()
        }

        private func updateDisplayLink() {
            link?.invalidate()
            link = nil
            guard window != nil, isActive else { return }
            target.reset()
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        deinit { link?.invalidate() }
    }

    final class DisplayLinkTarget: NSObject {
        private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "ChatPerformance")
        private var previousTime = 0.0
        private var windowStart = 0.0
        private var callbacks = 0
        private var delayedCallbacks = 0
        private var maxGapMS = 0.0
        var messageCount = 0
        var isStreaming = false

        func reset() {
            // Start a fresh foreground window rather than attributing parsing
            // from startup or the previous chat to the next frame sample.
            _ = PerformanceDiagnostics.drain()
            previousTime = 0
            windowStart = CACurrentMediaTime()
            callbacks = 0
            delayedCallbacks = 0
            maxGapMS = 0
        }

        @objc func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            defer { previousTime = now }
            guard previousTime > 0 else { return }
            let gap = now - previousTime
            let budget = link.targetTimestamp - link.timestamp
            callbacks += 1
            maxGapMS = max(maxGapMS, gap * 1_000)
            if gap > max(0.025, budget * 1.5) { delayedCallbacks += 1 }
            guard now - windowStart >= 2 else { return }
            logger.debug("PERFORMANCE: [Chat] phase=display_callbacks window_ms=\((now - self.windowStart) * 1_000) callbacks=\(self.callbacks) delayed_callbacks=\(self.delayedCallbacks) max_gap_ms=\(self.maxGapMS) budget_ms=\(budget * 1_000) messages=\(self.messageCount) streaming=\(self.isStreaming)")
            logRendererDiagnostics()
            windowStart = now
            callbacks = 0
            delayedCallbacks = 0
            maxGapMS = 0
        }

        private func logRendererDiagnostics() {
            // The SDK measures actual parsing, which happens after transcript
            // item preparation. Draining also bounds retained diagnostic keys.
            // These counters cover all SDK markdown in this process, including
            // sheets and other chat surfaces, rather than just the visible row.
            let snapshot = PerformanceDiagnostics.drain()
            if let parse = snapshot.measurements["markdown.parse.duration_ms"], parse.count > 0 {
                let bytes = snapshot.measurements["markdown.parse.input_bytes"]?.maximum ?? 0
                logger.debug("PERFORMANCE: [Chat] phase=markdown_parse scope=process samples=\(parse.count) total_ms=\(parse.total) avg_ms=\(parse.total / Double(parse.count)) max_ms=\(parse.maximum) max_input_bytes=\(bytes)")
            }
            let hits = snapshot.counters["markdown.cache.hit", default: 0]
            let misses = snapshot.counters["markdown.cache.miss", default: 0]
            let large = snapshot.counters["markdown.cache.skipped_large", default: 0]
            let live = snapshot.counters["markdown.cache.skipped_live", default: 0]
            let scrolls = snapshot.counters["scroll.actual.total", default: 0]
            let updates = snapshot.counters["mobile.transcript.body_updates", default: 0]
            logger.debug("PERFORMANCE: [Chat] phase=renderer_counters scope=process cache_hits=\(hits) cache_misses=\(misses) uncached_large=\(large) uncached_live=\(live) automatic_scrolls=\(scrolls) transcript_body_updates=\(updates)")
        }
    }
}
#endif
