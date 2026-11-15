import SwiftUI
import RxCodeCore
import RxCodeSync

// MARK: - Briefing List Card (Compact for Content Column)

struct BriefingListCard: View {
    let group: GroupedBriefing
    let projectName: String
    let activeJobCount: Int
    let ciStatus: ProjectCIStatus?
    let isSelected: Bool

    private var threadCount: Int { group.threads.count }

    var body: some View {
        HStack(spacing: 12) {
            // Project icon
            ZStack {
                Circle()
                    .fill(accentGradient.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accentGradient)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: group.branch.lowercased() == "unknown" ? "plus.circle" : "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(group.branch.lowercased() == "unknown" ? "Initialize Git" : group.branch)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)

                // Metadata
                BriefingFlowLayout(spacing: 8) {
                    if threadCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9, weight: .medium))
                            Text("\(threadCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    if activeJobCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text("\(activeJobCount) active", tableName: "Localizable")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    }

                    if let ciStatus {
                        MobileCIStatusChip(status: ciStatus, compact: true)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(group.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

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

// MARK: - Briefing List Card Button Style

struct BriefingListCardButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        MobileCardButtonStyle(isSelected: isSelected).makeBody(configuration: configuration)
    }
}
