import SwiftUI

/// Outlined label pill (version, tag, story) matching GitHub's field chips.
///
/// Shared so the task board, the task form, and the chat message list all draw
/// the same chip for the same field.
@MainActor
public struct TaskPill: View {
    public let text: String
    public var icon: String?
    public var tint: Color

    public init(text: String, icon: String? = nil, tint: Color = ClaudeTheme.textSecondary) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(8), weight: .semibold))
            }
            Text(text)
                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}
