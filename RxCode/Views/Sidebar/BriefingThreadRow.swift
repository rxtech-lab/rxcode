import SwiftUI
import Foundation
import RxCodeCore

// MARK: - Briefing Thread Row

struct BriefingThreadRow: View {
    let item: ThreadSummaryItem
    let isInProgress: Bool
    let todoProgress: ChatTodoProgress?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 14)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isInProgress {
                    BriefingThreadProgressBadge(progress: todoProgress)
                } else {
                    Text(Self.compactDate(item.updatedAt))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .help(isInProgress ? progressHelpText : "Open thread")
        .accessibilityLabel(accessibilityLabel)
    }

    private var progressHelpText: String {
        guard let todoProgress, todoProgress.total > 0 else {
            return String(localized: "Response in progress")
        }
        return String(localized: "Response in progress. Todos \(todoProgress.done)/\(todoProgress.total)")
    }

    private var accessibilityLabel: String {
        if isInProgress {
            return String(localized: "\(item.title), in progress")
        }
        return item.title
    }

    static func compactDate(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct BriefingThreadProgressBadge: View {
    let progress: ChatTodoProgress?

    private var fraction: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return min(1, max(0, Double(progress.done) / Double(progress.total)))
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let fraction {
                    ProgressView(value: fraction, total: 1)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .frame(width: 10, height: 10)

            Text("In progress")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ClaudeTheme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(ClaudeTheme.accent.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(ClaudeTheme.accent.opacity(0.25), lineWidth: 0.5)
        )
    }
}
