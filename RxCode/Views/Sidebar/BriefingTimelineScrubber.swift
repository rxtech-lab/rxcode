import SwiftUI
import RxCodeCore

/// A dated anchor on the briefing timeline: the content offset where a day
/// section starts inside the scroll view.
struct BriefingTimelineMarker: Identifiable, Equatable {
    let id: String
    let date: Date
    let offset: CGFloat
}

/// Scroll position and day markers of the briefing timeline. Observed only by
/// the scrubber so scroll updates don't invalidate the whole briefing list.
@Observable
final class BriefingTimelineScrollMetrics {
    struct Value: Equatable {
        var offset: CGFloat = 0
        var maxOffset: CGFloat = 0
    }

    var value = Value()
    /// Day-section markers, ordered by their content offset (top to bottom).
    var markers: [BriefingTimelineMarker] = []

    /// Installed by the timeline table view to perform programmatic scrolls.
    @ObservationIgnored var scrollHandler: ((CGFloat) -> Void)?

    func scroll(to offset: CGFloat) {
        scrollHandler?(offset)
    }
}

/// Google Photos–style fast-scroll rail shown on the right of the briefing
/// list, laid out beside the scroll view. Month / year labels sit at the proportional position of the first
/// section they cover; dragging or clicking the rail scrolls the list, and a
/// date pill beside the thumb always shows the day currently in view. The pill
/// stays inside the rail so it never covers briefing content.
struct BriefingTimelineScrubber: View {
    let metrics: BriefingTimelineScrollMetrics

    private var markers: [BriefingTimelineMarker] { metrics.markers }

    /// Current vertical content offset of the scroll view.
    private var contentOffset: CGFloat { metrics.value.offset }
    /// Largest scrollable offset (`contentHeight - containerHeight`).
    private var maxOffset: CGFloat { metrics.value.maxOffset }

    @State private var isDragging = false
    @State private var hoverY: CGFloat?

    private static let verticalInset: CGFloat = 12
    private static let thumbHeight: CGFloat = 26
    private static let minimumLabelSpacing: CGFloat = 18
    private static let railWidth: CGFloat = 76
    private static let trackInset: CGFloat = 6
    private static let labelTrailingInset: CGFloat = 14
    /// Month labels this close to the date pill are hidden to avoid overlap.
    private static let pillClearance: CGFloat = 14

    var body: some View {
        if maxOffset > 0 {
            rail
        }
    }

    private var rail: some View {
        GeometryReader { proxy in
            let trackHeight = max(1, proxy.size.height - Self.verticalInset * 2)
            let thumbY = Self.verticalInset + progress * trackHeight
            let indicatorY = isDragging ? thumbY : (hoverY ?? thumbY)
            let isActive = isDragging || hoverY != nil
            let labelWidth = proxy.size.width - Self.labelTrailingInset

            ZStack(alignment: .topTrailing) {
                // Wide transparent hit area so the rail is easy to grab.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())

                Capsule(style: .continuous)
                    .fill(ClaudeTheme.border.opacity(0.35))
                    .frame(width: 2, height: trackHeight)
                    .position(x: proxy.size.width - Self.trackInset, y: Self.verticalInset + trackHeight / 2)
                    .allowsHitTesting(false)

                ForEach(visibleLabels(trackHeight: trackHeight), id: \.marker.id) { label in
                    let y = Self.verticalInset + label.position
                    labelView(label)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: y)
                        .opacity(abs(y - indicatorY) < Self.pillClearance ? 0 : 1)
                        .allowsHitTesting(false)
                }

                thumb
                    .position(x: proxy.size.width - Self.trackInset, y: thumbY)
                    .allowsHitTesting(false)

                if let marker = marker(atTrackY: indicatorY - Self.verticalInset, trackHeight: trackHeight) {
                    datePill(for: marker.date, isActive: isActive)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: indicatorY)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        scrub(to: value.location.y, trackHeight: trackHeight)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverY = location.y
                case .ended: hoverY = nil
                }
            }
            .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .frame(width: Self.railWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefing timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let step = maxOffset * 0.1
            switch direction {
            case .increment: metrics.scroll(to: min(maxOffset, contentOffset + step))
            case .decrement: metrics.scroll(to: max(0, contentOffset - step))
            @unknown default: break
            }
        }
    }

    // MARK: - Geometry

    private var progress: CGFloat {
        guard maxOffset > 0 else { return 0 }
        return min(1, max(0, contentOffset / maxOffset))
    }

    private func trackPosition(forOffset offset: CGFloat, trackHeight: CGFloat) -> CGFloat {
        guard maxOffset > 0 else { return 0 }
        return min(1, max(0, offset / maxOffset)) * trackHeight
    }

    private func scrub(to y: CGFloat, trackHeight: CGFloat) {
        let fraction = min(1, max(0, (y - Self.verticalInset) / trackHeight))
        metrics.scroll(to: fraction * maxOffset)
    }

    /// The last marker whose track position is at or above `trackY`.
    private func marker(atTrackY trackY: CGFloat, trackHeight: CGFloat) -> BriefingTimelineMarker? {
        let target = min(1, max(0, trackY / trackHeight)) * maxOffset
        return markers.last { $0.offset <= target + 1 } ?? markers.first
    }

    // MARK: - Labels

    private struct TimelineLabel {
        let marker: BriefingTimelineMarker
        let text: String
        let isYear: Bool
        let position: CGFloat
    }

    /// One label per month (year labels when the year changes), dropping any
    /// that would collide with the previous visible label.
    private func visibleLabels(trackHeight: CGFloat) -> [TimelineLabel] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: .now)
        var labels: [TimelineLabel] = []
        var lastMonth: DateComponents?
        var lastYear: Int?
        var lastPosition: CGFloat = -.greatestFiniteMagnitude

        for marker in markers {
            let month = calendar.dateComponents([.year, .month], from: marker.date)
            guard month != lastMonth else { continue }
            lastMonth = month

            let year = month.year ?? currentYear
            let isYear = lastYear != nil && year != lastYear
            let isFirst = lastYear == nil
            lastYear = year

            let position = trackPosition(forOffset: marker.offset, trackHeight: trackHeight)
            // Year changes win over the spacing rule so the rail never hides
            // a year boundary behind a neighbouring month label.
            if position - lastPosition < Self.minimumLabelSpacing {
                guard isYear, let last = labels.last, !last.isYear else { continue }
                labels.removeLast()
            }

            let text: String
            if isYear || (isFirst && year != currentYear) {
                text = String(year)
            } else {
                text = marker.date.formatted(.dateTime.month(.abbreviated))
            }
            labels.append(TimelineLabel(marker: marker, text: text, isYear: isYear, position: position))
            lastPosition = position
        }
        return labels
    }

    private func labelView(_ label: TimelineLabel) -> some View {
        Text(label.text)
            .font(.system(size: 10, weight: label.isYear ? .bold : .medium).monospacedDigit())
            .foregroundStyle(label.isYear ? ClaudeTheme.textSecondary : ClaudeTheme.textTertiary)
            .lineLimit(1)
            .fixedSize()
            .opacity(isDragging || hoverY != nil ? 1 : 0.85)
    }

    // MARK: - Thumb & date pill

    private var thumb: some View {
        Capsule(style: .continuous)
            .fill(isDragging ? ClaudeTheme.accent : ClaudeTheme.textTertiary.opacity(0.7))
            .frame(width: 4, height: Self.thumbHeight)
            .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
    }

    private func datePill(for date: Date, isActive: Bool) -> some View {
        Text(Self.pillText(for: date))
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(isActive ? ClaudeTheme.textOnAccent : ClaudeTheme.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? ClaudeTheme.accent : ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(isActive ? 0 : 0.6), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
    }

    /// Month and day, plus the year for dates outside the current year.
    private static func pillText(for date: Date) -> String {
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }

    private var accessibilityValue: String {
        guard let marker = markers.last(where: { $0.offset <= contentOffset + 1 }) ?? markers.first else {
            return ""
        }
        return marker.date.formatted(date: .abbreviated, time: .omitted)
    }
}
