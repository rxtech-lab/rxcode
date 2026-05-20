//
//  RxCodeWidgetLiveActivity.swift
//  RxCodeWidget
//
//  Live Activity for an RxCode ongoing job. Mirrors the desktop menubar:
//  an "Ongoing job" title plus todo-list progress while the agent works,
//  and a "Done" state when it finishes.
//

import ActivityKit
import WidgetKit
import SwiftUI

/// RxCode terracotta accent (#D97757).
private let rxAccent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

struct RxCodeWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RxCodeJobActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            JobLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(rxAccent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase == .done ? "checkmark.circle.fill" : "hammer.fill")
                        .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(trailingLabel(for: context.state))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JobExpandedBottomView(context: context)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .done ? "checkmark.circle.fill" : "hammer.fill")
                    .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
            } compactTrailing: {
                Text(trailingLabel(for: context.state))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
            } minimal: {
                Image(systemName: context.state.phase == .done ? "checkmark.circle.fill" : "hammer.fill")
                    .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
            }
            .widgetURL(URL(string: "rxcode://thread/\(context.attributes.sessionID)"))
            .keylineTint(rxAccent)
        }
    }

    /// Compact label: a "✓" once done, "3/5" with a todo list, "•••" otherwise.
    private func trailingLabel(for state: RxCodeJobActivityAttributes.ContentState) -> String {
        if state.phase == .done { return "Done" }
        if state.hasTodos { return "\(state.todoDone)/\(state.todoTotal)" }
        return "•••"
    }
}

// MARK: - Lock screen

private struct JobLockScreenView: View {
    let context: ActivityViewContext<RxCodeJobActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: context.state.phase == .done ? "checkmark.circle.fill" : "hammer.fill")
                    .foregroundStyle(context.state.phase == .done ? Color.green : rxAccent)
                Text(context.state.phase == .done ? "Job done" : "Ongoing job")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if context.state.phase == .running, context.state.hasTodos {
                    Text("\(context.state.todoDone)/\(context.state.todoTotal)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(rxAccent)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                if !context.attributes.projectName.isEmpty {
                    Text(context.attributes.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            JobProgressView(state: context.state)

            if context.state.phase == .running,
               let step = context.state.currentStep, !step.isEmpty {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}

// MARK: - Dynamic Island expanded bottom

private struct JobExpandedBottomView: View {
    let context: ActivityViewContext<RxCodeJobActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !context.attributes.projectName.isEmpty {
                Text(context.attributes.projectName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            JobProgressView(state: context.state)
            if context.state.phase == .running,
               let step = context.state.currentStep, !step.isEmpty {
                Text(step)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Progress bar

/// A capsule progress bar driven by the job's todo list. Falls back to an
/// indeterminate-looking full accent bar when the job has no todo list, and a
/// solid green bar once the job is done.
private struct JobProgressView: View {
    let state: RxCodeJobActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(state.phase == .done ? Color.green : rxAccent)
                    .frame(width: max(6, geo.size.width * fillFraction))
            }
        }
        .frame(height: 6)
    }

    private var fillFraction: Double {
        if state.phase == .done { return 1 }
        if state.hasTodos { return state.fractionComplete }
        return 0.15  // no todo list: a small "working" sliver
    }
}

// MARK: - Previews

extension RxCodeJobActivityAttributes {
    fileprivate static var preview: RxCodeJobActivityAttributes {
        RxCodeJobActivityAttributes(
            sessionID: "demo",
            projectName: "RxCode",
            title: "Add live activity support"
        )
    }
}

extension RxCodeJobActivityAttributes.ContentState {
    fileprivate static var running: RxCodeJobActivityAttributes.ContentState {
        .init(phase: .running, todoDone: 2, todoTotal: 5,
              currentStep: "Implementing widget UI", updatedAt: 0)
    }

    fileprivate static var done: RxCodeJobActivityAttributes.ContentState {
        .init(phase: .done, todoDone: 5, todoTotal: 5, currentStep: nil, updatedAt: 0)
    }
}

#Preview("Live Activity", as: .content, using: RxCodeJobActivityAttributes.preview) {
    RxCodeWidgetLiveActivity()
} contentStates: {
    RxCodeJobActivityAttributes.ContentState.running
    RxCodeJobActivityAttributes.ContentState.done
}
