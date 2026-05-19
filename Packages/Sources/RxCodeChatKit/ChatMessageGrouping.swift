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
        if accumulator.count >= minGroupSize {
            result.append(ChatMessageGroup(id: accumulator[0].id, messages: accumulator, isTransientGroup: true))
        } else {
            for message in accumulator {
                result.append(ChatMessageGroup(id: message.id, messages: [message], isTransientGroup: false))
            }
        }
        accumulator = []
    }

    for message in messages {
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

private func chatIsPureTransientMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary else { return false }
    let hasVisibleText = message.blocks.contains {
        guard let text = $0.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if hasVisibleText { return false }

    let toolCalls = message.blocks.compactMap(\.toolCall)
    guard !toolCalls.isEmpty else { return false }

    let hasNonTransient = toolCalls.contains { !ToolCategory(toolName: $0.name).isTransient }
    return !hasNonTransient
}

private func chatIsInvisibleMessage(_ message: ChatMessage) -> Bool {
    guard message.role == .assistant, !message.isError, !message.isCompactBoundary, !message.isStreaming else { return false }
    return message.blocks.isEmpty
}
