import Foundation
import RxCodeCore

struct ChatMessageGroup: Identifiable {
    let id: UUID
    let messages: [ChatMessage]
    let isTransientGroup: Bool
}

func chatPartitionByStreaming(_ messages: [ChatMessage]) -> (settled: [ChatMessage], streaming: [ChatMessage]) {
    var settled: [ChatMessage] = []
    var streaming: [ChatMessage] = []
    for message in messages {
        if message.isStreaming {
            streaming.append(message)
        } else {
            settled.append(message)
        }
    }
    return (settled, streaming)
}

func chatStreamingBoundaryIndex(in messages: [ChatMessage]) -> Int {
    var index = messages.count - 1
    while index >= 0 && messages[index].role == .assistant && !messages[index].isError {
        index -= 1
    }
    return index + 1
}

func chatSuppressPlanReadyFollowups(in messages: [ChatMessage]) -> [ChatMessage] {
    var result: [ChatMessage] = []
    var assistantRun: [ChatMessage] = []

    func flushAssistantRun() {
        guard !assistantRun.isEmpty else { return }
        let hasExitPlan = assistantRun.contains { PlanLogic.containsExitPlanMode($0) }
        var hasRecentPlanCard = false

        for message in assistantRun {
            if hasExitPlan && PlanLogic.isPurePlanFileWriteMessage(message) {
                continue
            }

            _ = hasRecentPlanCard

            if PlanLogic.containsExitPlanMode(message) {
                hasRecentPlanCard = true
            }
            result.append(message)
        }

        assistantRun.removeAll(keepingCapacity: true)
    }

    for message in messages {
        if message.role == .user {
            flushAssistantRun()
            result.append(message)
            continue
        }

        assistantRun.append(message)
    }
    flushAssistantRun()

    return result
}

func chatMessageGroups(_ messages: [ChatMessage], minGroupSize: Int = 2) -> [ChatMessageGroup] {
    var result: [ChatMessageGroup] = []
    var accumulator: [ChatMessage] = []

    func flushAccumulator() {
        guard !accumulator.isEmpty else { return }
        if accumulator.reduce(0, { $0 + $1.blocks.compactMap(\.toolCall).count }) >= minGroupSize {
            result.append(ChatMessageGroup(id: accumulator[0].id, messages: accumulator, isTransientGroup: true))
        } else {
            for message in accumulator {
                result.append(ChatMessageGroup(id: message.id, messages: [message], isTransientGroup: false))
            }
        }
        accumulator = []
    }

    for message in messages.flatMap(chatSplitToolRuns) {
        if chatIsPureTransientMessage(message) {
            accumulator.append(message)
        } else if chatIsInvisibleMessage(message) {
            continue
        } else {
            flushAccumulator()
            result.append(ChatMessageGroup(id: message.id, messages: [message], isTransientGroup: false))
        }
    }
    flushAccumulator()

    return result
}

/// Splits an assistant message that mixes narration with groupable tool calls
/// (e.g. "I'll check the file…" + Bash) into segments, so its tool calls can join
/// the adjacent tool-only messages instead of forming a separate group. The first
/// segment keeps the message id; later segments get stable ids derived from it.
func chatSplitToolRuns(_ message: ChatMessage) -> [ChatMessage] {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary,
          message.attachmentPaths.isEmpty,
          message.blocks.contains(where: { $0.toolCall.map(chatCanGroupTool) == true }),
          message.blocks.contains(where: { !chatIsGroupableBlock($0) })
    else { return [message] }

    var runs: [(isTools: Bool, blocks: [MessageBlock])] = []
    for block in message.blocks {
        // Blank text between tool calls renders nothing; keep it in the tool run.
        let isTools = chatIsGroupableBlock(block) || (runs.last?.isTools == true && chatIsBlankText(block))
        if isTools == runs.last?.isTools {
            runs[runs.count - 1].blocks.append(block)
        } else {
            runs.append((isTools, [block]))
        }
    }

    // The duration footer belongs on a visible bubble, not inside a collapsed tool group.
    let footerIndex = runs.lastIndex { !$0.isTools } ?? runs.count - 1
    return runs.enumerated().map { index, run in
        ChatMessage(
            id: index == 0 ? message.id : chatSegmentID(message.id, index: index),
            role: message.role,
            blocks: run.blocks,
            isStreaming: message.isStreaming,
            isResponseComplete: message.isResponseComplete,
            timestamp: message.timestamp,
            duration: index == footerIndex ? message.duration : nil
        )
    }
}

private func chatIsGroupableBlock(_ block: MessageBlock) -> Bool {
    block.toolCall.map(chatCanGroupTool) ?? false
}

private func chatIsBlankText(_ block: MessageBlock) -> Bool {
    guard let text = block.text else { return false }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func chatSegmentID(_ id: UUID, index: Int) -> UUID {
    var bytes = id.uuid
    bytes.15 ^= UInt8(truncatingIfNeeded: index)
    bytes.14 ^= 0xA5
    return UUID(uuid: bytes)
}

private func chatIsPureTransientMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary,
          message.attachmentPaths.isEmpty, message.blocks.allSatisfy({ $0.isText || $0.toolCall != nil })
    else { return false }
    let hasVisibleText = message.blocks.contains {
        guard let text = $0.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if hasVisibleText { return false }

    let toolCalls = message.blocks.compactMap(\.toolCall)
    guard !toolCalls.isEmpty else { return false }

    let hasNonTransient = toolCalls.contains { !chatCanGroupTool($0) }
    return !hasNonTransient
}

private func chatIsInvisibleMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary, !message.isStreaming,
          message.attachmentPaths.isEmpty else { return false }
    // Whitespace-only text (e.g. a "\n\n" emitted between tool calls) renders nothing,
    // so it must not split a run of tool calls into separate groups.
    return message.blocks.allSatisfy {
        $0.toolCall == nil && ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Presentation policy independent of provider-specific tool names and permission categories.
func chatCanGroupTool(_ tool: ToolCall) -> Bool {
    !["askuserquestion", "imagegeneration"].contains(tool.name.lowercased())
        && !PlanLogic.isExitPlanMode(tool)
        && !PlanLogic.isPlanFileWrite(tool)
        && tool.name != ReviewCountdownCard.toolName
        && !JSONUITool.matches(tool)
}
