import SwiftUI

/// Shared sidebar row used by the macOS history list and the iOS / iPadOS
/// threads list. Pure presentation: callers supply a value-typed model.
public struct SessionSidebarRow: View {
    public let title: String
    public let projectName: String?
    public let updatedAt: Date
    public let isPinned: Bool
    public let isBackgroundStreaming: Bool

    public init(
        title: String,
        projectName: String? = nil,
        updatedAt: Date,
        isPinned: Bool = false,
        isBackgroundStreaming: Bool = false
    ) {
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isBackgroundStreaming = isBackgroundStreaming
    }

    public var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                TypewriterTitleText(title: title.prefix(1).uppercased() + title.dropFirst())
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: title)

                HStack(spacing: 4) {
                    if let projectName {
                        Text(projectName)
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accent.opacity(0.8))
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: ClaudeTheme.size(10)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }

                    Text(Self.compactElapsed(since: updatedAt))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
            }

            Spacer()

            if isBackgroundStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .help("Response in progress in the background")
            }

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    public static func compactElapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "0m" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}
