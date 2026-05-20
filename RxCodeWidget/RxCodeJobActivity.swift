//
//  RxCodeJobActivity.swift
//  RxCode
//
//  Shared Live Activity attributes for an RxCode "job" — one in-progress chat
//  session (agent run). This file is compiled into BOTH the RxCodeMobile app
//  target (which starts and observes the activity) and the RxCodeWidget
//  extension (which renders it).
//
//  The desktop builds the APNs `content-state` JSON by hand, so the field
//  names and types here are a wire contract: keep them in sync with
//  `MobileSyncService` on macOS. Only plain JSON-friendly types are used
//  (String / Int / Double / String-backed enum) so ActivityKit can decode a
//  pushed content-state without a custom strategy.
//

#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity descriptor for a single ongoing RxCode job.
struct RxCodeJobActivityAttributes: ActivityAttributes {
    /// The mutable part, refreshed via APNs `update` pushes from the desktop.
    struct ContentState: Codable, Hashable {
        /// Lifecycle phase of the job.
        enum Phase: String, Codable, Hashable {
            /// The agent is still working.
            case running
            /// The agent finished. The activity stays in this state until the
            /// user dismisses it — the desktop never ends it automatically.
            case done
        }

        var phase: Phase
        /// Completed todo count. Zero/`todoTotal == 0` means no todo list.
        var todoDone: Int
        /// Total todo count; zero when the job has no todo list yet.
        var todoTotal: Int
        /// Active-form label of the in-progress todo (e.g. "Running tests").
        /// `nil` when there is no todo list or nothing is in progress.
        var currentStep: String?
        /// Desktop-side update time, unix seconds. A `Double` rather than
        /// `Date` so a pushed content-state decodes without a date strategy.
        var updatedAt: Double

        /// Fractional progress 0...1; zero when the job has no todo list.
        var fractionComplete: Double {
            guard todoTotal > 0 else { return 0 }
            return min(1, max(0, Double(todoDone) / Double(todoTotal)))
        }

        var hasTodos: Bool { todoTotal > 0 }
    }

    /// Chat-session id the job belongs to. Stable for the activity's lifetime.
    var sessionID: String
    /// Project display name, shown as the subtitle.
    var projectName: String
    /// Thread title.
    var title: String
}
#endif
