//
//  RxCodeWidgetData.swift
//  RxCode
//
//  Shared snapshot for the RxCode home-screen widget. Compiled into BOTH the
//  RxCodeMobile app target (which writes it) and the RxCodeWidget extension
//  (which reads it). The data crosses the process boundary through the
//  App Group container, and the app nudges WidgetKit to reload after a write.
//

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the RxCode home-screen widget renders: the number of ongoing jobs and
/// the agents' rate-limit usage, mirrored from the desktop menubar.
struct RxCodeWidgetData: Codable, Equatable {
    /// Number of in-progress jobs (streaming chat sessions).
    var jobCount: Int
    /// Claude Code 5-hour utilization, 0...100. `nil` when not signed in.
    var ccUsagePercent: Double?
    /// Claude Code 7-day utilization, 0...100. `nil` when not signed in.
    var ccWeeklyUsagePercent: Double?
    /// Codex 5-hour utilization, 0...100. `nil` when not signed in.
    var codexUsagePercent: Double?
    /// Codex 7-day utilization, 0...100. `nil` when not signed in.
    var codexWeeklyUsagePercent: Double?
    /// When the desktop produced this snapshot, unix seconds.
    var updatedAt: Double

    static let empty = RxCodeWidgetData(
        jobCount: 0,
        ccUsagePercent: nil,
        ccWeeklyUsagePercent: nil,
        codexUsagePercent: nil,
        codexWeeklyUsagePercent: nil,
        updatedAt: 0
    )
}

/// Reads and writes `RxCodeWidgetData` in the App Group shared by the app and
/// the widget extension.
enum RxCodeWidgetStore {
    /// App Group identifier — must match the `com.apple.security.application-groups`
    /// entitlement on both the app and the widget targets.
    static let appGroupID = "group.app.rxlab.rxcodemobile"

    private static let snapshotKey = "widget.snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Current snapshot, or `.empty` when nothing has been written yet.
    static func load() -> RxCodeWidgetData {
        guard let data = defaults?.data(forKey: snapshotKey),
              let decoded = try? JSONDecoder().decode(RxCodeWidgetData.self, from: data)
        else { return .empty }
        return decoded
    }

    /// Persist a fresh snapshot and ask WidgetKit to reload the timeline.
    /// Called from the app (foreground sync and background widget push).
    static func save(_ snapshot: RxCodeWidgetData) {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
