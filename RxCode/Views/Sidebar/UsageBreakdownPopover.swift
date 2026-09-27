import Charts
import SwiftUI
import RxCodeCore

/// Popover shown from the briefing usage tiles: one or more donut charts, each
/// with a legend table so slice identity never relies on color alone.
struct UsageBreakdownPopover: View {
    struct Slice: Identifiable, Equatable {
        let id: String
        let label: String
        let detail: String?
        let value: Double
        let color: Color

        /// Named slices beyond this count fold into a single "Other" slice.
        static let maxNamedSlices = 5

        /// Categorical palette in fixed order (light / dark steps), assigned by
        /// slice position after sorting — never cycled.
        static let palette: [Color] = [
            Color(light: .hex(0x2A78D6), dark: .hex(0x3987E5)), // blue
            Color(light: .hex(0xEB6834), dark: .hex(0xD95926)), // orange
            Color(light: .hex(0x1BAF7A), dark: .hex(0x199E70)), // aqua
            Color(light: .hex(0xEDA100), dark: .hex(0xC98500)), // yellow
            Color(light: .hex(0xE87BA4), dark: .hex(0xD55181)), // magenta
        ]
        static let otherColor = Color(light: .hex(0xA3A29B), dark: .hex(0x6B6A64))

        /// Builds colored slices from raw entries, dropping zero values and
        /// folding the tail into "Other".
        static func folded(
            _ entries: [(id: String, label: String, detail: String?, value: Double)],
            sorted: Bool = true
        ) -> [Slice] {
            var items = entries.filter { $0.value > 0 }
            if sorted { items.sort { $0.value > $1.value } }
            var slices = items.prefix(maxNamedSlices).enumerated().map { index, entry in
                Slice(id: entry.id, label: entry.label, detail: entry.detail, value: entry.value, color: palette[index])
            }
            let rest = items.dropFirst(maxNamedSlices)
            if !rest.isEmpty {
                slices.append(Slice(
                    id: "other",
                    label: String(localized: "Other"),
                    detail: String(localized: "\(rest.count) more"),
                    value: rest.reduce(0) { $0 + $1.value },
                    color: otherColor
                ))
            }
            return slices
        }
    }

    struct ChartSpec: Identifiable {
        let title: String
        let unit: String
        let slices: [Slice]
        /// Formats slice values and the donut total; defaults to compact counts.
        var format: (Double) -> String = Self.compactCount

        static func compactCount(_ value: Double) -> String {
            Int(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        var id: String { title }
    }

    let title: String
    let subtitle: String
    let charts: [ChartSpec]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            HStack(alignment: .top, spacing: 20) {
                ForEach(charts) { chart in
                    UsageDonutChart(spec: chart)
                        .frame(width: 240)
                }
            }
        }
        .padding(18)
    }
}

/// One donut chart plus its legend table. Hovering a slice or a legend row
/// highlights it and shows its value in the donut center.
private struct UsageDonutChart: View {
    let spec: UsageBreakdownPopover.ChartSpec

    @State private var selectedAngle: Double?
    @State private var hoveredSliceId: String?

    private var total: Double {
        spec.slices.reduce(0) { $0 + $1.value }
    }

    /// Slice under the pointer, from either the chart or the legend.
    private var highlighted: UsageBreakdownPopover.Slice? {
        if let hoveredSliceId {
            return spec.slices.first { $0.id == hoveredSliceId }
        }
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        for slice in spec.slices {
            cumulative += slice.value
            if selectedAngle <= cumulative { return slice }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            if spec.slices.isEmpty {
                Text("No data in this window.")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                chart
                legend
            }
        }
    }

    private var chart: some View {
        let highlightedId = highlighted?.id
        return Chart(spec.slices) { slice in
            SectorMark(
                angle: .value(spec.unit, slice.value),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(slice.color)
            .opacity(highlightedId == nil || highlightedId == slice.id ? 1 : 0.35)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let rect = geometry[frame]
                    centerLabel
                        .frame(width: rect.width * 0.55)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(height: 160)
        .animation(.easeInOut(duration: 0.15), value: highlightedId)
    }

    private var centerLabel: some View {
        let slice = highlighted
        return VStack(spacing: 1) {
            Text(spec.format(slice?.value ?? total))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(slice.map { percent($0.value) } ?? spec.unit)
                .font(.system(size: 10))
                .foregroundStyle(ClaudeTheme.textTertiary)
            if let slice {
                Text(slice.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(spec.slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(slice.color)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(slice.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = slice.detail {
                            Text(detail)
                                .font(.system(size: 9.5))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(spec.format(slice.value))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Text(percent(slice.value))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hoveredSliceId == slice.id ? ClaudeTheme.surfaceSecondary : .clear)
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hoveredSliceId = slice.id
                    } else if hoveredSliceId == slice.id {
                        hoveredSliceId = nil
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        guard total > 0 else { return "0%" }
        return (value / total).formatted(.percent.precision(.fractionLength(0)))
    }
}
