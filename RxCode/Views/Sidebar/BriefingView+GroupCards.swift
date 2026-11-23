import SwiftUI
import Foundation
import RxCodeCore
import RxCodeChatKit

extension BriefingView {
    // MARK: - Group card

    func groupCard(_ group: BriefingGroup) -> some View {
        BriefingPerformanceLog.log("group card body\(BriefingTimelineScrollActivity.isAnyScrolling ? " [scrolling]" : "") \(group.id)")
        let project = BriefingPerformanceLog.measure("projectsById for group card", threshold: 1) {
            projectsById[group.projectId]
        }
        return VStack(alignment: .leading, spacing: 12) {
            groupCardHeader(group, project: project)

            if let briefing = group.briefing {
                ClaudeThemeDivider()
                BriefingSummaryPreview(
                    text: briefing.briefing,
                    maximumHeight: Self.maximumSummaryPreviewHeight
                ) {
                    presentedBriefing = group
                }
            }

            if !group.plans.isEmpty {
                ClaudeThemeDivider()
                planList(Array(group.plans.prefix(Self.visibleThreadCount)))
            }

            if !group.threadSummaries.isEmpty {
                ClaudeThemeDivider()
                threadList(Array(group.threadSummaries.prefix(Self.visibleThreadCount)), totalCount: group.threadSummaries.count)
            }

            if group.threadSummaries.count > Self.visibleThreadCount || group.plans.count > Self.visibleThreadCount {
                BriefingShowMoreButton {
                    presentedBriefing = group
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            // Shadow the card shape only; shadowing the whole card makes SwiftUI
            // shadow every text run and chip, which is slow to draw while scrolling.
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
                .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    func briefingSheet(_ group: BriefingGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupCardHeader(group, project: projectsById[group.projectId])
                .padding(24)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let briefing = group.briefing {
                        MarkdownContentView(text: GeneratedTextSanitizer.cleanMarkdownDocument(briefing.briefing))
                    }
                    if !group.plans.isEmpty {
                        planList(group.plans)
                    }
                    if !group.threadSummaries.isEmpty {
                        if group.briefing != nil {
                            ClaudeThemeDivider()
                        }
                        threadList(group.threadSummaries, totalCount: group.threadSummaries.count)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }

            ClaudeThemeDivider()
            HStack {
                Spacer()
                Button("Done") { presentedBriefing = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 420, idealHeight: 660, maxHeight: .infinity)
        .background(ClaudeTheme.background)
    }

    private func groupCardHeader(_ group: BriefingGroup, project: Project?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? "Unknown project")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Created \(Self.creationTime(group.createdAt)) · Updated \(Self.compactDate(group.updatedAt))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                        .help("Created \(group.createdAt.formatted(date: .complete, time: .shortened))")
                }

                Spacer(minLength: 0)

                copyButton(for: group)

                if let project {
                    cardMenu(for: group, project: project)
                }
            }

            // Status chips wrap onto multiple lines so a narrow card never
            // truncates the branch / CI / release / PR indicators.
            FlowLayout(spacing: 6, lineSpacing: 6) {
                BriefingInfoChip(icon: "arrow.triangle.branch", text: group.branch, accented: true)
                ciChip(for: group)
                if let project, let version = appState.projectLatestReleaseVersion(project) {
                    BriefingInfoChip(icon: "tag.fill", text: version)
                }
                BriefingPRStatusView(
                    projectId: group.projectId,
                    branch: group.branch,
                    project: project
                )
            }
        }
    }


    private func planList(_ plans: [CodingPlanActivity]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coding Plans")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
            ForEach(plans) { plan in
                Button {
                    presentedBriefing = nil
                    appState.selectSession(id: plan.threadID, in: windowState)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: plan.title)
                            .font(.subheadline.weight(.medium))
                        Text(verbatim: plan.briefingDescription)
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open plan · \(plan.id.uuidString)")
            }
        }
    }

    // MARK: - Thread list (compact rows)

    private func threadList(_ items: [ThreadSummaryItem], totalCount: Int) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Threads")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("\(totalCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ClaudeTheme.surfaceSecondary))
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
                threadRow(item)
            }
        }
    }

    private func threadRow(_ item: ThreadSummaryItem) -> some View {
        BriefingThreadRow(
            item: item,
            isInProgress: appState.sessionActivity[item.sessionId]?.isStreaming == true,
            todoProgress: appState.todoProgress(forSessionId: item.sessionId),
            reviewPassed: appState.reviewPassedBySession[item.sessionId]
        ) {
            presentedBriefing = nil
            appState.selectSession(id: item.sessionId, in: windowState)
        }
    }
}
