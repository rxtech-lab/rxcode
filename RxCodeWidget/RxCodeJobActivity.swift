//
//  RxCodeJobActivity.swift
//  RxCode
//
//  Shared Live Activity attributes for RxCode's ongoing jobs. A *single*
//  Live Activity per device aggregates every in-progress agent run — one
//  activity, no matter how many jobs are running, keeps the app well within
//  the scarce iOS push-to-start budget.
//
//  This file is compiled into BOTH the RxCodeMobile app target (which starts
//  and observes the activity) and the RxCodeWidget extension (which renders
//  it).
//
//  The desktop builds the APNs `content-state` JSON by hand, so the field
//  names and types here are a wire contract: keep them in sync with
//  `MobileSyncService` on macOS. Only plain JSON-friendly types are used
//  (String / Int / Double / String-backed enum / arrays of those) so
//  ActivityKit can decode a pushed content-state without a custom strategy.
//

#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity descriptor for RxCode's ongoing jobs. The activity itself
/// carries no static attributes — it is device-scoped and every job lives in
/// the mutable `ContentState`.
struct RxCodeJobActivityAttributes: ActivityAttributes {
    /// The mutable part, refreshed via APNs `update` pushes from the desktop.
    struct ContentState: Codable, Hashable {
        /// One agent job (chat session) tracked by the activity.
        struct Job: Codable, Hashable, Identifiable {
            /// Lifecycle phase of a single job.
            enum Phase: String, Codable, Hashable {
                /// The agent is still working.
                case running
                /// The agent finished. The job stays in the list — in this
                /// state — until the user dismisses the whole activity.
                case done
            }

            /// Chat-session id the job belongs to. Stable for its lifetime
            /// and used as the deep-link target.
            var id: String
            /// Lifecycle phase.
            var phase: Phase
            /// Thread title. The desktop swaps in an AI-summarized title
            /// shortly after the job starts, pushed as a content update.
            var title: String
            /// Project display name, shown as the subtitle.
            var projectName: String
            /// Completed todo count. `todoTotal == 0` means no todo list.
            var todoDone: Int
            /// Total todo count; zero when the job has no todo list yet.
            var todoTotal: Int
            /// Active-form label of the in-progress todo (e.g. "Running
            /// tests"). `nil` when there is no todo list or nothing is active.
            var currentStep: String?

            /// `true` when the job has a todo list to render as steps.
            var hasTodos: Bool { todoTotal > 0 }

            /// Fractional progress 0...1; zero when the job has no todo list.
            var fractionComplete: Double {
                guard todoTotal > 0 else { return 0 }
                return min(1, max(0, Double(todoDone) / Double(todoTotal)))
            }

            var displayIdentity: String {
                [
                    phase.rawValue,
                    projectName,
                    title,
                    "\(todoDone)/\(todoTotal)",
                    currentStep ?? "",
                ].joined(separator: "\u{1F}")
            }
        }

        /// Every tracked job: those still running plus recently finished ones,
        /// in the order they started.
        var jobs: [Job]
        /// Desktop-side update time, unix seconds. A `Double` rather than
        /// `Date` so a pushed content-state decodes without a date strategy.
        var updatedAt: Double

        /// Client-side normalized job list keyed by the chat-session id. APNs
        /// updates can race a foreground local start, so renderers should read
        /// this list instead of the raw wire array.
        var deduplicatedJobs: [Job] {
            var ordered: [Job] = []
            var indicesByID: [String: Int] = [:]
            for job in jobs {
                if let index = indicesByID[job.id] {
                    ordered[index] = job
                } else {
                    indicesByID[job.id] = ordered.count
                    ordered.append(job)
                }
            }

            var visible: [Job] = []
            var indicesByDisplay: [String: Int] = [:]
            for job in ordered {
                let key = job.displayIdentity
                if let index = indicesByDisplay[key] {
                    visible[index] = job
                } else {
                    indicesByDisplay[key] = visible.count
                    visible.append(job)
                }
            }
            return visible
        }

        /// Jobs still being worked on.
        var runningJobs: [Job] { deduplicatedJobs.filter { $0.phase == .running } }
        /// Jobs that have finished.
        var doneJobs: [Job] { deduplicatedJobs.filter { $0.phase == .done } }
        /// Count of jobs still running — the headline number for the UI.
        var runningCount: Int { runningJobs.count }
        /// Count of unique jobs represented by this activity.
        var jobCount: Int { deduplicatedJobs.count }
        /// `true` once every tracked job has finished.
        var allDone: Bool { !deduplicatedJobs.isEmpty && runningJobs.isEmpty }
        /// The single job to feature when exactly one is running, else `nil`.
        var soleRunningJob: Job? {
            runningJobs.count == 1 ? runningJobs.first : nil
        }
    }
}
#endif
