import Foundation

// MARK: - Run turns

/// One prompt the task's thread was given and the agent's final answer to it.
public struct TaskRunTurn: Identifiable, Equatable, Codable, Sendable {
    public let id: Int
    public let prompt: String
    /// The last non-empty assistant text before the next prompt; empty while
    /// the turn is still running or when it produced no text.
    public let response: String
    public let didError: Bool

    public init(id: Int, prompt: String, response: String, didError: Bool) {
        self.id = id
        self.prompt = prompt
        self.response = response
        self.didError = didError
    }

    /// Groups a transcript into prompt → final-response pairs. Intermediate
    /// assistant text (narration between tool calls) is dropped: the Run tab
    /// shows outcomes, the chat shows the process.
    public static func turns(from messages: [ChatMessage]) -> [TaskRunTurn] {
        var turns: [TaskRunTurn] = []
        var prompt: String?
        var response = ""
        var didError = false

        func flush() {
            guard let prompt else { return }
            turns.append(TaskRunTurn(id: turns.count, prompt: prompt, response: response, didError: didError))
        }

        for message in messages {
            switch message.role {
            case .user where !message.isError:
                flush()
                prompt = promptText(of: message)
                response = ""
                didError = false
            case .assistant:
                if message.isError {
                    didError = true
                } else {
                    let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { response = text }
                }
            default:
                continue
            }
        }
        flush()
        return turns
    }

    /// A user message's text, led by its attachments as the `[Attached …]` /
    /// `[Link: …]` lines `TaskPromptContent` renders as chips. The chat stores
    /// follow-up attachments beside the text rather than in it, so they're
    /// added back here unless the text already carries them.
    private static func promptText(of message: ChatMessage) -> String {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = message.attachmentPaths.compactMap { info -> String? in
            switch info.type {
            case "image", "file": "[Attached \(info.type): \(info.path)]"
            case "link": "[Link: \(info.path)]"
            default: nil
            }
        }
        .filter { !content.contains($0) }
        guard !references.isEmpty else { return content }
        return (references + [content]).joined(separator: "\n")
    }
}
