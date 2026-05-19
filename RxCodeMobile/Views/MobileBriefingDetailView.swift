import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

struct MobileBriefingDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    let groupKey: BriefingGroupKey

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summarySection
                threadsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await state.refreshSnapshot()
        }
    }

    private var group: GroupedBriefing? {
        groupBriefings(
            briefings: state.branchBriefings.filter {
                $0.projectId == groupKey.projectId && $0.branch == groupKey.branch
            },
            threads: state.threadSummaries.filter {
                $0.projectId == groupKey.projectId && $0.branch == groupKey.branch
            }
        ).first
    }

    private var projectName: String {
        state.projects.first(where: { $0.id == groupKey.projectId })?.name ?? "Unknown Project"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(projectName)
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Label(groupKey.branch, systemImage: "arrow.triangle.branch")
                if let updatedAt = group?.updatedAt {
                    Text(updatedAt.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let summary = group?.briefing?.briefing, !summary.isEmpty {
                ChatTextContentView(
                    markdown: summary,
                    size: 16,
                    color: .primary,
                    lineSpacing: 3
                )
            } else {
                Text("No summary available yet.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var threadsSection: some View {
        let threads = group?.threads ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("Threads")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if threads.isEmpty {
                Text("No threads on this branch yet.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.sessionId) {
                            threadRow(thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func threadRow(_ thread: MobileThreadSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !thread.summary.isEmpty {
                    ChatTextContentView(
                        markdown: thread.summary,
                        size: 12,
                        color: .secondary,
                        lineSpacing: 1,
                        maximumNumberOfLines: 3
                    )
                }
                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
