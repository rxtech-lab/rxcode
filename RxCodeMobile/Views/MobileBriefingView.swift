import SwiftUI
import RxCodeCore
import RxCodeSync

struct MobileBriefingView: View {
    @EnvironmentObject private var state: MobileAppState

    private struct GroupedBriefing: Identifiable {
        let projectId: UUID
        let branch: String
        let briefing: MobileBranchBriefing?
        let threads: [MobileThreadSummary]
        let updatedAt: Date

        var id: String { "\(projectId.uuidString)::\(branch)" }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Briefings Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Briefings appear here after threads finish on your Mac.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ForEach(groups) { group in
                        briefingCard(group)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Briefing")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await state.refreshSnapshot() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var projectsById: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    private var groups: [GroupedBriefing] {
        var buckets: [String: GroupedBriefing] = [:]

        for briefing in state.branchBriefings {
            let key = "\(briefing.projectId.uuidString)::\(briefing.branch)"
            buckets[key] = GroupedBriefing(
                projectId: briefing.projectId,
                branch: briefing.branch,
                briefing: briefing,
                threads: buckets[key]?.threads ?? [],
                updatedAt: max(briefing.updatedAt, buckets[key]?.updatedAt ?? .distantPast)
            )
        }

        for thread in state.threadSummaries {
            let key = "\(thread.projectId.uuidString)::\(thread.branch)"
            let existing = buckets[key]
            var threads = existing?.threads ?? []
            threads.append(thread)
            buckets[key] = GroupedBriefing(
                projectId: thread.projectId,
                branch: thread.branch,
                briefing: existing?.briefing,
                threads: threads.sorted { $0.updatedAt > $1.updatedAt },
                updatedAt: max(thread.updatedAt, existing?.updatedAt ?? .distantPast)
            )
        }

        return buckets.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func briefingCard(_ group: GroupedBriefing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projectsById[group.projectId]?.name ?? "Unknown Project")
                    .font(.headline)
                HStack(spacing: 8) {
                    Label(group.branch, systemImage: "arrow.triangle.branch")
                    Text(group.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let briefing = group.briefing?.briefing, !briefing.isEmpty {
                Text(briefing)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if !group.threads.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Threads")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.threads) { thread in
                        threadRow(thread)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func threadRow(_ thread: MobileThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !thread.summary.isEmpty {
                Text(thread.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .textSelection(.enabled)
    }
}
