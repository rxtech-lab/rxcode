import SwiftUI
import ClarcCore

/// Minimal historical bubble for a Claude Code `AskUserQuestion` tool call.
/// Shows only "Agent asked N questions" plus whether the user has answered.
/// The full question text and answer details live in the question sheet —
/// the chat transcript stays uncluttered.
struct AskUserQuestionView: View {
    let toolCall: ToolCall

    private var parsed: AskUserQuestion? {
        AskUserQuestion(input: toolCall.input)
    }

    private var hasAnswer: Bool {
        toolCall.result?.isEmpty == false
    }

    var body: some View {
        if let parsed, !parsed.questions.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: hasAnswer ? "checkmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                    .foregroundStyle(hasAnswer ? ClaudeTheme.statusSuccess : ClaudeTheme.accent)
                    .frame(width: 16, height: 16)

                Text(promptText(count: parsed.questions.count))
                    .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 6)

                Text(hasAnswer
                     ? String(localized: "Answered", bundle: .module)
                     : String(localized: "Waiting for answer", bundle: .module))
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                    .foregroundStyle(hasAnswer ? ClaudeTheme.statusSuccess : ClaudeTheme.textTertiary)
            }
            .bubbleStyle(.tool)
        } else {
            ToolResultView(toolCall: toolCall)
        }
    }

    private func promptText(count: Int) -> String {
        if count == 1 {
            return String(localized: "Agent asked a question", bundle: .module)
        }
        return String(
            format: NSLocalizedString(
                "Agent asked %d questions",
                bundle: .module,
                comment: "Inline summary when the assistant invokes AskUserQuestion with multiple questions. %d is the number of questions."
            ),
            count
        )
    }
}
