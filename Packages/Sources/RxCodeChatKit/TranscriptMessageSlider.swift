import RxCodeCore
import SwiftUI

struct TranscriptMessageStop: Identifiable {
    let id: String
    let row: Int

    static func stops(in items: [ChatTranscriptListItem]) -> [Self] {
        // MessageList keeps the first occurrence of each ID before assigning
        // native row indexes. Accessories and tool groups each occupy a row.
        var seen = Set<String>()
        var stops: [Self] = []
        for item in items where seen.insert(item.id).inserted {
            if item.isUserMessage {
                stops.append(Self(id: item.id, row: seen.count - 1))
            }
        }
        return stops
    }
}

@Observable
final class TranscriptMessageNavigation {
    @ObservationIgnored lazy var surface = TranscriptScrollSurface { [weak self] row, atBottom in
        self?.userDidScroll(to: row, atBottom: atBottom)
    }

    private(set) var isVisible = false
    private(set) var visibleRow = 0
    private var browsingLatestID: String?
    @ObservationIgnored private var isInteracting = false
    @ObservationIgnored private var hideTimer: Timer?

    func userDidScroll(to row: Int, atBottom: Bool) {
        guard !isInteracting else { return }
        if atBottom { followLatest() }
        visibleRow = atBottom ? .max : row
        isVisible = true
        scheduleHide()
    }

    func isReadingHistory(latestUserID: String?) -> Bool {
        browsingLatestID != nil && browsingLatestID == latestUserID
    }

    func followLatest() {
        browsingLatestID = nil
    }

    func select(row: Int, latestUserID: String) -> Bool {
        browsingLatestID = latestUserID
        visibleRow = row
        scheduleHide()
        return surface.scroll(toRow: row)
    }

    func setInteracting(_ interacting: Bool) {
        isInteracting = interacting
        if interacting {
            hideTimer?.invalidate()
            hideTimer = nil
        } else if isVisible {
            scheduleHide()
        }
    }

    func reset() {
        hideTimer?.invalidate()
        hideTimer = nil
        isInteracting = false
        isVisible = false
        visibleRow = 0
        followLatest()
    }

    private func scheduleHide() {
        guard !isInteracting else { return }
        let deadline = Date.now.addingTimeInterval(1)
        if let hideTimer {
            hideTimer.fireDate = deadline
            return
        }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isVisible = false
                self?.hideTimer = nil
            }
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

struct TranscriptMessageSliderOverlay: View {
    let items: [ChatTranscriptListItem]
    let navigation: TranscriptMessageNavigation
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        // Index the loaded messages only while the slider is in use. The
        // slider observes row changes independently of the transcript.
        let shown = navigation.isVisible || voiceOver
        ZStack(alignment: .trailing) {
            if shown {
                let stops = TranscriptMessageStop.stops(in: items)
                if !stops.isEmpty {
                    TranscriptMessageSlider(stops: stops, navigation: navigation, onSelect: onSelect)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown)
        .allowsHitTesting(shown)
    }
}

private struct TranscriptMessageSlider: View {
    let stops: [TranscriptMessageStop]
    let navigation: TranscriptMessageNavigation
    let onSelect: (Int) -> Void

    @GestureState private var dragging = false
    @State private var dragID: String?

    private var currentIndex: Int {
        if let dragID, let index = stops.firstIndex(where: { $0.id == dragID }) { return index }
        let row = navigation.visibleRow
        return stops.lastIndex { $0.row <= row } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 10
            let travel = max(1, geometry.size.height - 2 * inset)
            let fraction = stops.count == 1 ? 0.5 : CGFloat(currentIndex) / CGFloat(stops.count - 1)
            let thumbY = inset + travel * fraction
            let trackX = geometry.size.width - 10

            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(ClaudeTheme.textTertiary.opacity(0.45))
                    .frame(width: 3, height: travel)
                    .position(x: trackX, y: inset + travel / 2)
                if stops.count > 1, travel / CGFloat(stops.count - 1) >= 10 {
                    ForEach(stops.indices, id: \.self) { index in
                        Capsule()
                            .fill(ClaudeTheme.textTertiary)
                            .frame(width: 7, height: 2)
                            .position(x: trackX, y: inset + travel * CGFloat(index) / CGFloat(stops.count - 1))
                    }
                }
                Capsule()
                    .fill(ClaudeTheme.accent)
                    .frame(width: dragging ? 8 : 6, height: 20)
                    .overlay(alignment: .leading) {
                        if dragID != nil {
                            Text("\(currentIndex + 1) of \(stops.count)")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .fixedSize()
                                .alignmentGuide(.leading) { $0.width + 8 }
                                .allowsHitTesting(false)
                        }
                    }
                    .position(x: trackX, y: thumbY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, active, _ in active = true }
                    .onChanged { value in
                        let fraction = min(1, max(0, (value.location.y - inset) / travel))
                        let index = Int((fraction * CGFloat(stops.count - 1)).rounded())
                        let stop = stops[index]
                        guard stop.id != dragID else { return }
                        navigation.setInteracting(true)
                        dragID = stop.id
                        onSelect(stop.row)
                    }
                    .onEnded { _ in endDrag() }
            )
        }
        .frame(width: hitWidth)
        .frame(maxHeight: min(280, max(52, CGFloat(stops.count - 1) * 20 + 20)))
        .padding(.vertical, 8)
        .onChange(of: dragging) { _, active in
            if !active { endDrag() }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: dragID) { _, new in new != nil }
        #else
        .help("Jump between your messages")
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("user-message-slider")
        .accessibilityLabel("Your messages")
        .accessibilityValue("Message \(currentIndex + 1) of \(stops.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(stops[min(stops.count - 1, currentIndex + 1)].row)
            case .decrement: onSelect(stops[max(0, currentIndex - 1)].row)
            @unknown default: break
            }
        }
    }

    private var hitWidth: CGFloat {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    private func endDrag() {
        dragID = nil
        navigation.setInteracting(false)
    }
}
