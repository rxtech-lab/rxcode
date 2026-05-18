import RxCodeCore
import SwiftUI

/// Renders the current thread's title as a button that reveals the
/// generated thread summary in a popover when tapped. Falls back to
/// plain title text when no summary is available.
struct ThreadTitlePopoverButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let title: String

    @State private var showingPopover = false

    private var summaryItem: ThreadSummaryItem? {
        guard !windowState.showingBriefing,
              let sessionId = windowState.currentSessionId
        else { return nil }
        _ = appState.threadSummaryRevision
        return appState.threadStore.threadSummaryItem(sessionId: sessionId)
    }

    private var trimmedSummary: String {
        summaryItem?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        let hasSummary = !trimmedSummary.isEmpty
        Button {
            if hasSummary { showingPopover.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                if hasSummary {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasSummary)
        .help(hasSummary ? "Show thread summary" : "")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ThreadSummaryPopoverContent(item: summaryItem)
        }
    }
}

private struct ThreadSummaryPopoverContent: View {
    let item: ThreadSummaryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(3)

                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)

                Divider()

                ScrollView {
                    Text(Self.attributedSummary(item.summary))
                        .font(.system(size: 12.5))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            } else {
                Text("No summary yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(14)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 480)
    }

    private static func attributedSummary(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }
}
