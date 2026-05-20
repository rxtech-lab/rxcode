//
//  RxCodeWidgetLiveActivity.swift
//  RxCodeWidget
//
//  Live Activity for RxCode's ongoing jobs. A single activity aggregates
//  every in-progress agent job: it shows a step progress bar when exactly one
//  job is running, and an in-progress count plus a compact list when several
//  are. A green "all done" state stays on screen until the user dismisses it.
//

import ActivityKit
import WidgetKit
import SwiftUI

/// RxCode terracotta accent (#D97757).
private let rxAccent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
/// Unfilled progress-track color.
private let rxTrack = Color.secondary.opacity(0.25)

private typealias JobState = RxCodeJobActivityAttributes.ContentState
private typealias Job = RxCodeJobActivityAttributes.ContentState.Job

struct RxCodeWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RxCodeJobActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            JobsLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(rxAccent)

        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: leadingIcon(state))
                        .foregroundStyle(state.allDone ? Color.green : rxAccent)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(statusBadge(state))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(state.allDone ? Color.green : rxAccent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(headlineTitle(state))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JobsExpandedBottomView(state: state)
                }
            } compactLeading: {
                Image(systemName: leadingIcon(state))
                    .foregroundStyle(state.allDone ? Color.green : rxAccent)
            } compactTrailing: {
                Text(compactTrailing(state))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.allDone ? Color.green : rxAccent)
            } minimal: {
                Image(systemName: leadingIcon(state))
                    .foregroundStyle(state.allDone ? Color.green : rxAccent)
            }
            .widgetURL(deepLink(state))
            .keylineTint(rxAccent)
        }
    }
}

// MARK: - Presentation helpers

private func leadingIcon(_ state: JobState) -> String {
    state.allDone ? "checkmark.circle.fill" : "hammer.fill"
}

/// Headline title: the sole running job's title, or an N-jobs summary.
private func headlineTitle(_ state: JobState) -> String {
    if let job = state.soleRunningJob { return job.title }
    if state.allDone {
        return state.jobs.count == 1 ? "Job done" : "\(state.jobs.count) jobs done"
    }
    return "\(state.runningCount) jobs running"
}

/// Trailing status badge for the lock screen / expanded island.
private func statusBadge(_ state: JobState) -> String {
    if state.allDone { return "Done" }
    if let job = state.soleRunningJob {
        return job.hasTodos ? "\(job.todoDone)/\(job.todoTotal)" : "Working"
    }
    return "\(state.runningCount) running"
}

/// Compact Dynamic Island trailing — tight on space, so digits only.
private func compactTrailing(_ state: JobState) -> String {
    if state.allDone { return "✓" }
    if let job = state.soleRunningJob {
        return job.hasTodos ? "\(job.todoDone)/\(job.todoTotal)" : "•••"
    }
    return "\(state.runningCount)"
}

/// Deep-link to the single running job, or the app root for several.
private func deepLink(_ state: JobState) -> URL? {
    if let job = state.soleRunningJob {
        return URL(string: "rxcode://thread/\(job.id)")
    }
    return URL(string: "rxcode://")
}

// MARK: - Lock screen

private struct JobsLockScreenView: View {
    let state: JobState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: leadingIcon(state))
                .foregroundStyle(state.allDone ? Color.green : rxAccent)
            Text(headerLabel)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusBadge(state))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(state.allDone ? Color.green : rxAccent)
        }
    }

    private var headerLabel: String {
        if state.allDone { return "Jobs done" }
        return state.runningCount == 1 ? "Ongoing job" : "Ongoing jobs"
    }

    @ViewBuilder
    private var content: some View {
        if let job = state.soleRunningJob {
            // Exactly one job: feature it with a full step progress bar.
            SoleJobView(job: job)
        } else if state.allDone {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(state.jobs.count) \(state.jobs.count == 1 ? "job" : "jobs") completed")
                    .font(.subheadline.weight(.medium))
                StepProgressBar(done: 1, total: 0, isComplete: true)
            }
        } else {
            // Several jobs: lead with the count, list the rest.
            MultiJobView(state: state)
        }
    }
}

/// The featured single-job layout: title, project, and a step progress bar.
private struct SoleJobView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                if !job.projectName.isEmpty {
                    Text(job.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            StepProgressBar(done: job.todoDone, total: job.todoTotal)
            if let step = job.currentStep, !step.isEmpty {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The multi-job layout: a compact row per running job, then an overflow line.
private struct MultiJobView: View {
    let state: JobState
    private let maxRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(state.runningJobs.prefix(maxRows))) { job in
                JobRowView(job: job)
            }
            let overflow = state.runningCount - maxRows
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One compact row: a title line plus a thin step progress bar.
private struct JobRowView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(rxAccent)
                    .frame(width: 5, height: 5)
                Text(job.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(job.hasTodos ? "\(job.todoDone)/\(job.todoTotal)" : "•••")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StepProgressBar(done: job.todoDone, total: job.todoTotal, height: 4)
        }
    }
}

// MARK: - Dynamic Island expanded bottom

private struct JobsExpandedBottomView: View {
    let state: JobState

    var body: some View {
        if let job = state.soleRunningJob {
            VStack(alignment: .leading, spacing: 6) {
                if !job.projectName.isEmpty {
                    Text(job.projectName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                StepProgressBar(done: job.todoDone, total: job.todoTotal)
                if let step = job.currentStep, !step.isEmpty {
                    Text(step)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if state.allDone {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("All jobs done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.runningJobs.prefix(2))) { job in
                    JobRowView(job: job)
                }
                let overflow = state.runningCount - 2
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Step progress bar

/// A segmented "step" progress bar — one capsule per todo, filled as steps
/// complete. Above `stepCap` steps the segments would be too thin, so it
/// falls back to a continuous bar; with no todo list it shows a small
/// "working" sliver; once complete every segment turns green.
private struct StepProgressBar: View {
    /// Completed step count.
    let done: Int
    /// Total step count; 0 renders the indeterminate sliver.
    let total: Int
    /// Paints the whole bar in the done color.
    var isComplete: Bool = false
    /// Bar height — thinner for compact list rows.
    var height: CGFloat = 6

    /// Above this step count discrete segments get too thin to read.
    private let stepCap = 12

    var body: some View {
        GeometryReader { geo in
            bar(in: geo.size.width)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func bar(in width: CGFloat) -> some View {
        if total >= 1, total <= stepCap {
            let spacing: CGFloat = total > 8 ? 2 : 3
            let each = (width - spacing * CGFloat(total - 1)) / CGFloat(total)
            HStack(spacing: spacing) {
                ForEach(0..<total, id: \.self) { idx in
                    Capsule()
                        .fill(idx < done || isComplete ? fillColor : rxTrack)
                        .frame(width: max(2, each))
                }
            }
        } else {
            ZStack(alignment: .leading) {
                Capsule().fill(rxTrack)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(6, width * fillFraction))
            }
        }
    }

    private var fillColor: Color { isComplete ? .green : rxAccent }

    private var fillFraction: Double {
        if isComplete { return 1 }
        guard total > 0 else { return 0.16 }  // no todo list: a "working" sliver
        return min(1, max(0, Double(done) / Double(total)))
    }
}

// MARK: - Previews

extension RxCodeJobActivityAttributes.ContentState {
    fileprivate static func makeJob(
        _ id: String, _ title: String, _ project: String,
        phase: Job.Phase = .running, done: Int = 0, total: Int = 0,
        step: String? = nil
    ) -> Job {
        Job(id: id, phase: phase, title: title, projectName: project,
            todoDone: done, todoTotal: total, currentStep: step)
    }

    /// Exactly one running job — featured with a step progress bar.
    fileprivate static var oneRunning: Self {
        .init(jobs: [
            makeJob("a", "Add live activity support", "RxCode",
                    done: 2, total: 5, step: "Implementing widget UI"),
        ], updatedAt: 0)
    }

    /// One running job with no todo list — shows the "working" sliver.
    fileprivate static var oneRunningNoTodos: Self {
        .init(jobs: [
            makeJob("a", "Investigate flaky sync test", "RxCodeMobile"),
        ], updatedAt: 0)
    }

    /// Several running jobs — shows the in-progress count and a list.
    fileprivate static var manyRunning: Self {
        .init(jobs: [
            makeJob("a", "Add live activity support", "RxCode", done: 2, total: 5),
            makeJob("b", "Fix mobile sync reconnect", "RxCodeMobile", done: 1, total: 3),
            makeJob("c", "Refactor marketplace fetch", "RxCode"),
            makeJob("d", "Update onboarding copy", "Homepage", done: 3, total: 4),
        ], updatedAt: 0)
    }

    /// Every job finished — the green terminal state.
    fileprivate static var allDone: Self {
        .init(jobs: [
            makeJob("a", "Add live activity support", "RxCode",
                    phase: .done, done: 5, total: 5),
            makeJob("b", "Fix mobile sync reconnect", "RxCodeMobile",
                    phase: .done, done: 3, total: 3),
        ], updatedAt: 0)
    }
}

#Preview("Live Activity", as: .content, using: RxCodeJobActivityAttributes()) {
    RxCodeWidgetLiveActivity()
} contentStates: {
    RxCodeJobActivityAttributes.ContentState.oneRunning
    RxCodeJobActivityAttributes.ContentState.oneRunningNoTodos
    RxCodeJobActivityAttributes.ContentState.manyRunning
    RxCodeJobActivityAttributes.ContentState.allDone
}
