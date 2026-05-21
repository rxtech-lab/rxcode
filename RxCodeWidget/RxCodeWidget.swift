//
//  RxCodeWidget.swift
//  RxCodeWidget
//
//  Home-screen widget mirroring the desktop menubar: the number of ongoing
//  jobs plus Claude Code and Codex rate-limit usage. Data is written by the
//  iOS app into the shared App Group and refreshed via background APNs pushes.
//

import SwiftUI
import WidgetKit

/// RxCode terracotta accent (#D97757).
private let rxAccent = Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

// MARK: - Timeline

struct RxCodeWidgetEntry: TimelineEntry {
    let date: Date
    let data: RxCodeWidgetData
}

struct RxCodeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RxCodeWidgetEntry {
        RxCodeWidgetEntry(
            date: Date(),
            data: RxCodeWidgetData(
                jobCount: 2,
                ccUsagePercent: 45,
                ccWeeklyUsagePercent: 18,
                codexUsagePercent: 12,
                codexWeeklyUsagePercent: 7,
                updatedAt: 0
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RxCodeWidgetEntry) -> Void) {
        completion(RxCodeWidgetEntry(date: Date(), data: RxCodeWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RxCodeWidgetEntry>) -> Void) {
        let entry = RxCodeWidgetEntry(date: Date(), data: RxCodeWidgetStore.load())
        // The app pushes fresh data via background APNs; this hourly refresh is
        // just a fallback so the widget never goes fully stale.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
            ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Views

struct RxCodeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RxCodeWidgetProvider.Entry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumBody
        default:
            smallBody
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            jobsHeader
            Spacer(minLength: 0)
            providerUsageRow(
                label: "CC",
                fiveHour: entry.data.ccUsagePercent,
                weekly: entry.data.ccWeeklyUsagePercent
            )
            providerUsageRow(
                label: "CX",
                fiveHour: entry.data.codexUsagePercent,
                weekly: entry.data.codexWeeklyUsagePercent
            )
        }
    }

    private var mediumBody: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                jobsHeader
                Spacer(minLength: 0)
                Text(updatedLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                providerUsageRow(
                    label: "Claude Code",
                    fiveHour: entry.data.ccUsagePercent,
                    weekly: entry.data.ccWeeklyUsagePercent
                )
                providerUsageRow(
                    label: "Codex",
                    fiveHour: entry.data.codexUsagePercent,
                    weekly: entry.data.codexWeeklyUsagePercent
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var jobsHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "hammer.fill")
                    .font(.caption2)
                    .foregroundStyle(rxAccent)
                Text("RxCode")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.data.jobCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.data.jobCount > 0 ? rxAccent : .primary)
                Text(entry.data.jobCount == 1 ? "job" : "jobs")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func providerUsageRow(label: String, fiveHour: Double?, weekly: Double?) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            // 5-hour usage with solid bar
            usageBarRow(
                period: "5h",
                percent: fiveHour,
                barStyle: .solid
            )
            // 7-day usage with striped/dimmed bar
            usageBarRow(
                period: "7d",
                percent: weekly,
                barStyle: .dimmed
            )
        }
    }

    @ViewBuilder
    private func usageBarRow(period: String, percent: Double?, barStyle: UsageBarStyle) -> some View {
        HStack(spacing: family == .systemSmall ? 4 : 6) {
            Text(period)
                .font(.system(size: family == .systemSmall ? 8 : 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: family == .systemSmall ? 14 : 16, alignment: .trailing)
            UsageBar(percent: percent, style: barStyle)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: family == .systemSmall ? 9 : 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(percent == nil ? .tertiary : (barStyle == .solid ? .primary : .secondary))
                .frame(width: family == .systemSmall ? 24 : 28, alignment: .trailing)
        }
    }

    private var updatedLabel: String {
        guard entry.data.updatedAt > 0 else { return "No data yet" }
        let date = Date(timeIntervalSince1970: entry.data.updatedAt)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

/// Style variants for usage bars to differentiate 5h vs 7d.
private enum UsageBarStyle {
    case solid   // 5-hour: full opacity, prominent
    case dimmed  // 7-day: reduced opacity, subtler
}

/// A thin capsule usage bar that tints toward red as utilization climbs.
private struct UsageBar: View {
    let percent: Double?
    var style: UsageBarStyle = .solid

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(style == .solid ? 0.22 : 0.12))
                Capsule()
                    .fill(tint.opacity(style == .solid ? 1.0 : 0.5))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: style == .solid ? 6 : 4)
    }

    private var fraction: Double {
        guard let percent else { return 0 }
        return min(1, max(0, percent / 100))
    }

    private var tint: Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return rxAccent
    }
}

// MARK: - Widget

struct RxCodeWidget: Widget {
    let kind: String = "RxCodeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RxCodeWidgetProvider()) { entry in
            RxCodeWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("RxCode Jobs")
        .description("Ongoing jobs and Claude Code / Codex usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    RxCodeWidget()
} timeline: {
    RxCodeWidgetEntry(
        date: .now,
        data: RxCodeWidgetData(
            jobCount: 3,
            ccUsagePercent: 64,
            ccWeeklyUsagePercent: 31,
            codexUsagePercent: 22,
            codexWeeklyUsagePercent: 14,
            updatedAt: Date().timeIntervalSince1970
        )
    )
    RxCodeWidgetEntry(date: .now, data: .empty)
}

#Preview(as: .systemMedium) {
    RxCodeWidget()
} timeline: {
    RxCodeWidgetEntry(
        date: .now,
        data: RxCodeWidgetData(
            jobCount: 1,
            ccUsagePercent: 91,
            ccWeeklyUsagePercent: 67,
            codexUsagePercent: nil,
            codexWeeklyUsagePercent: nil,
            updatedAt: Date().timeIntervalSince1970
        )
    )
}
