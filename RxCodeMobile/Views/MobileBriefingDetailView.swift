import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

struct MobileBriefingDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Namespace private var glassNamespace
    let groupKey: BriefingGroupKey

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerCard
                summaryCard
                threadsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("briefing-detail-screen")
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

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 14) {
            // Project icon
            ZStack {
                Circle()
                    .fill(accentGradient.opacity(0.15))
                    .frame(width: 52, height: 52)
                
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accentGradient)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                
                HStack(spacing: 12) {
                    // Branch chip
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                        Text(groupKey.branch)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    
                    // Updated time
                    if let updatedAt = group?.updatedAt {
                        Text(updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Summary Card

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentGradient)
                
                Text("Summary")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if let summary = group?.briefing?.briefing, !summary.isEmpty {
                ChatTextContentView(
                    markdown: summary,
                    size: 15,
                    color: .primary,
                    lineSpacing: 4
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "text.justify.leading")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No summary yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("A summary will appear after threads complete")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Threads Section

    @ViewBuilder
    private var threadsSection: some View {
        let threads = group?.threads ?? []
        
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentGradient)
                
                Text("Threads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                
                if !threads.isEmpty {
                    Text("\(threads.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.leading, 4)

            if threads.isEmpty {
                emptyThreadsCard
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(threads) { thread in
                            NavigationLink(value: thread.sessionId) {
                                ThreadCard(thread: thread, namespace: glassNamespace)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("briefing-thread-row-\(thread.sessionId)")
                        }
                    }
                }
            }
        }
    }

    private var emptyThreadsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("No threads yet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Start a conversation from your Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Accent Gradient

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.6, blue: 0.4),
                Color(red: 0.85, green: 0.5, blue: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Thread Card

private struct ThreadCard: View {
    let thread: MobileThreadSummary
    let namespace: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thread icon
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "text.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                if !thread.summary.isEmpty {
                    ChatTextContentView(
                        markdown: thread.summary,
                        size: 13,
                        color: .secondary,
                        lineSpacing: 2,
                        maximumNumberOfLines: 3
                    )
                }
                
                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .glassEffectID(thread.id, in: namespace)
        .contentShape(.rect(cornerRadius: 16))
    }
}
