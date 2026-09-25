import AgentMarkdownUI
import RxCodeCore
import SwiftUI

// MARK: - Style

/// Tinting and sizing for `TaskPromptView`, so the same card reads correctly
/// on the task sheet's surface and inside the chat's accent-tinted user bubble.
public struct TaskPromptStyle {
    /// Scales a base point size. Chat text follows the message font setting,
    /// the task pages follow the UI font setting.
    public var fontSize: @MainActor @Sendable (CGFloat) -> CGFloat
    public var titleColor: Color
    public var labelColor: Color
    public var valueColor: Color
    public var pillTint: Color
    public var chipTextColor: Color
    public var chipBackground: Color
    public var dividerColor: Color
    public var markdown: MarkdownStyle
    /// Whether the Markdown body claims the full available width. The chat
    /// bubble hugs its content, so it passes `false`.
    public var expandsHorizontally: Bool

    public init(
        fontSize: @escaping @MainActor @Sendable (CGFloat) -> CGFloat,
        titleColor: Color,
        labelColor: Color,
        valueColor: Color,
        pillTint: Color,
        chipTextColor: Color,
        chipBackground: Color,
        dividerColor: Color,
        markdown: MarkdownStyle,
        expandsHorizontally: Bool
    ) {
        self.fontSize = fontSize
        self.titleColor = titleColor
        self.labelColor = labelColor
        self.valueColor = valueColor
        self.pillTint = pillTint
        self.chipTextColor = chipTextColor
        self.chipBackground = chipBackground
        self.dividerColor = dividerColor
        self.markdown = markdown
        self.expandsHorizontally = expandsHorizontally
    }

    /// The task form's Run tab: theme surface colors on the sheet background.
    public static var card: TaskPromptStyle {
        TaskPromptStyle(
            fontSize: { ClaudeTheme.size($0) },
            titleColor: ClaudeTheme.textPrimary,
            labelColor: ClaudeTheme.textTertiary,
            valueColor: ClaudeTheme.textPrimary,
            pillTint: ClaudeTheme.textSecondary,
            chipTextColor: ClaudeTheme.textSecondary,
            chipBackground: ClaudeTheme.surfaceElevated,
            dividerColor: ClaudeTheme.border,
            markdown: .rxCodeChat,
            expandsHorizontally: true
        )
    }

    /// The chat message list's user bubble: every color derives from
    /// `userBubbleText` so the card stays legible on the tinted bubble.
    public static var userBubble: TaskPromptStyle {
        let text = ClaudeTheme.userBubbleText
        return TaskPromptStyle(
            fontSize: { ClaudeTheme.messageSize($0) },
            titleColor: text,
            labelColor: text.opacity(0.7),
            valueColor: text,
            pillTint: text.opacity(0.85),
            chipTextColor: text.opacity(0.85),
            chipBackground: text.opacity(0.12),
            dividerColor: text.opacity(0.22),
            markdown: .rxCodeChatUser,
            expandsHorizontally: false
        )
    }
}

// MARK: - View

/// A thread's user message as a card: attachments as chips, the task title as
/// a heading, the description as Markdown, and the context list as labeled
/// pills. Follow-ups have no title and render as plain Markdown.
///
/// Shared by the task form's Run tab and the chat message list, so a task
/// dispatched to an agent reads the same in both places.
public struct TaskPromptView: View {
    let content: TaskPromptContent
    let style: TaskPromptStyle

    public init(content: TaskPromptContent, style: TaskPromptStyle = .card) {
        self.content = content
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = content.title {
                Text(title)
                    .font(.system(size: style.fontSize(15), weight: .semibold))
                    .foregroundStyle(style.titleColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.body.isEmpty {
                MarkdownContentView(
                    text: content.body,
                    style: style.markdown,
                    expandsHorizontally: style.expandsHorizontally
                )
            }

            if !content.fields.isEmpty {
                if content.title != nil {
                    Rectangle()
                        .fill(style.dividerColor)
                        .frame(height: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(content.fields, id: \.self) { field in
                        fieldRow(field)
                    }
                }
            }

            if !content.references.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(content.references, id: \.self) { reference in
                        referenceChip(reference)
                    }
                }
            }
        }
    }

    private func fieldRow(_ field: TaskPromptContent.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(field.label, systemImage: Self.icon(for: field.label))
                .font(.system(size: style.fontSize(11), weight: .medium))
                .foregroundStyle(style.labelColor)
                .frame(width: 110, alignment: .leading)

            if field.label == "Tags" {
                FlowLayout(spacing: 4) {
                    ForEach(Self.tags(in: field.value), id: \.self) { tag in
                        TaskPill(text: tag, tint: style.pillTint)
                    }
                }
            } else {
                Text(field.value)
                    .font(.system(size: style.fontSize(12)))
                    .foregroundStyle(style.valueColor)
                    .textSelection(.enabled)
            }
        }
    }

    private func referenceChip(_ reference: TaskPromptContent.Reference) -> some View {
        let icon: String = switch reference.kind {
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        }
        let name = reference.kind == .link
            ? reference.value
            : URL(fileURLWithPath: reference.value).lastPathComponent
        return Label(name, systemImage: icon)
            .font(.system(size: style.fontSize(11)))
            .foregroundStyle(style.chipTextColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(style.chipBackground))
            .help(reference.value)
    }

    private static func tags(in value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Icons for the labels `ProjectTask.agentPrompt` writes. The labels are
    /// the prompt's fixed English keys, not localized UI strings.
    private static func icon(for label: String) -> String {
        switch label {
        case "Story": "square.stack.3d.up"
        case "Type": "shippingbox"
        case "Priority": "flag"
        case "Tags": "tag"
        case "Target version": "number"
        case "Milestone": "flag.checkered"
        default: "info.circle"
        }
    }
}
