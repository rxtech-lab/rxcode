import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The reason a task needs attention, rendered as markdown. Shown under the
/// Details header, and as the last message of the Run transcript. Long
/// reasons are clipped to a few lines; hover for the full text or expand in place.
struct TaskAttentionBanner: View {
    let reason: String
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.statusWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs Attention")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                if isExpanded {
                    ScrollView {
                        reasonText
                    }
                    .frame(maxHeight: 180)
                } else {
                    reasonText
                        .frame(maxHeight: 54, alignment: .top)
                        .clipped()
                        .help(reason)
                }
            }
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less" : "Show full error message")
            .accessibilityLabel(isExpanded ? "Show less" : "Show full error message")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.statusWarning.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.statusWarning.opacity(0.4))
        )
        .accessibilityIdentifier("task-form-attention-banner")
    }

    private var reasonText: some View {
        MarkdownContentView(text: reason, style: .rxCodeCompact)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
