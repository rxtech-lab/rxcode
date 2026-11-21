import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Dedicated Full-Height Daily Workspace Report Sheet

struct PetDailyReportSheet: View {
    @Bindable var controller: PetController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let report = controller.latestDailyReport {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            summaryMetricsRow(report)
                            ClaudeThemeDivider()
                            MarkdownContentView(text: report.markdownBody)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Daily Report Yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Generate a workspace daily report summarizing completed tasks, active threads, briefings, scheduled runs, and CI health from the past 24 hours.")
                    } actions: {
                        Button {
                            Task { await controller.triggerDailyReport(speakAloud: true, openSheet: false) }
                        } label: {
                            Label("Generate Daily Report", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isGeneratingDailyReport)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClaudeTheme.background)
            .navigationTitle("Daily Workspace Report")
            .toolbar {
                if let report = controller.latestDailyReport {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            if controller.isStandaloneSpeaking {
                                controller.interruptSpeaking()
                            } else {
                                controller.readReportAloud(report)
                            }
                        } label: {
                            Label(
                                controller.isStandaloneSpeaking ? "Stop Reading" : "Read Aloud",
                                systemImage: controller.isStandaloneSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                            )
                        }
                        .disabled(controller.isMuted)
                    }

                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await controller.triggerDailyReport(speakAloud: false, openSheet: false) }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .disabled(controller.isGeneratingDailyReport)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 740, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .overlay {
            if controller.isGeneratingDailyReport {
                PetActionStatusOverlay(message: "Generating daily workspace report…")
            }
        }
    }

    private func summaryMetricsRow(_ report: PetDailyReport) -> some View {
        HStack(spacing: 12) {
            metricTile(title: "Done (24h)", value: "\(report.completedTasksCount)", tint: .green)
            metricTile(title: "In Progress", value: "\(report.inProgressTasksCount)", tint: .blue)
            metricTile(title: "In Review", value: "\(report.pendingReviewTasksCount)", tint: .orange)
            metricTile(title: "Active Threads", value: "\(report.activeThreadsCount)", tint: ClaudeTheme.accent)
            metricTile(title: "CI Status", value: report.ciFailing ? "Failing" : "Healthy", tint: report.ciFailing ? .red : .green)
        }
    }

    private func metricTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(value)
                .font(.system(size: ClaudeTheme.size(16), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
    }
}
