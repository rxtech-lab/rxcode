//
//  RxCodeWidget.swift
//  RxCodeWidget
//
//  Home-screen widget mirroring the desktop menubar: the number of ongoing
//  jobs plus Claude Code and Codex rate-limit usage. Data is written by the
//  iOS app into the shared App Group and refreshed via background APNs pushes.
//

import WidgetKit
import SwiftUI

/// RxCode terracotta accent (#D97757).
private let rxAccent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

// MARK: - Timeline

struct RxCodeWidgetEntry: TimelineEntry {
    let date: Date
    let data: RxCodeWidgetData
}

struct RxCodeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RxCodeWidgetEntry {
        RxCodeWidgetEntry(
            date: Date(),
            data: RxCodeWidgetData(jobCount: 2, ccUsagePercent: 45, codexUsagePercent: 12, updatedAt: 0)
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
        VStack(alignment: .leading, spacing: 10) {
            jobsHeader
            Spacer(minLength: 0)
            usageRow(label: "CC", percent: entry.data.ccUsagePercent)
            usageRow(label: "CX", percent: entry.data.codexUsagePercent)
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
            VStack(alignment: .leading, spacing: 12) {
                usageRow(label: "Claude Code", percent: entry.data.ccUsagePercent)
                usageRow(label: "Codex", percent: entry.data.codexUsagePercent)
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
    private func usageRow(label: String, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(percent == nil ? .secondary : .primary)
            }
            UsageBar(percent: percent)
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

/// A thin capsule usage bar that tints toward red as utilization climbs.
private struct UsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 5)
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
    RxCodeWidgetEntry(date: .now, data: RxCodeWidgetData(jobCount: 3, ccUsagePercent: 64, codexUsagePercent: 22, updatedAt: Date().timeIntervalSince1970))
    RxCodeWidgetEntry(date: .now, data: .empty)
}

#Preview(as: .systemMedium) {
    RxCodeWidget()
} timeline: {
    RxCodeWidgetEntry(date: .now, data: RxCodeWidgetData(jobCount: 1, ccUsagePercent: 91, codexUsagePercent: nil, updatedAt: Date().timeIntervalSince1970))
}
