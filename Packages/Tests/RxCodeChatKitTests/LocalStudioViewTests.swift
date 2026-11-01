import Foundation
import Testing
import RxCodeCore
@testable import RxCodeChatKit

@Suite("LocalStudios")
@MainActor
struct LocalStudioViewTests {
    private func call(_ id: String, _ name: String, result: String?, isError: Bool = false) -> ToolCall {
        ToolCall(id: id, name: name, result: result, isError: isError)
    }

    @Test("Image takes pair prompts with their files")
    func imageTakes() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "studio-\(UUID().uuidString).png")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let messages = [
            ChatMessage(role: .user, content: "a lighthouse"),
            ChatMessage(role: .assistant, blocks: [.toolCall(call("a", "ImageGeneration", result: #"{"savedPath":"\#(file.path)","seed":7}"#))]),
            ChatMessage(role: .user, content: "gone"),
            ChatMessage(role: .assistant, blocks: [.toolCall(call("b", "ImageGeneration", result: #"{"savedPath":"/nope/x.png"}"#))]),
            ChatMessage(role: .user, content: "broken"),
            ChatMessage(role: .assistant, blocks: [.toolCall(call("c", "ImageGeneration", result: #"{"displayError":"no VAE"}"#, isError: true))]),
            ChatMessage(role: .user, content: "painting"),
        ]
        let takes = GenerationTake.takes(from: messages, toolName: "ImageGeneration", isStreaming: true)
        #expect(takes.map(\.phase) == [.ready, .missing, .failed, .generating])
        #expect(takes[0].int("seed") == 7)
        #expect(takes[2].failureMessage == "no VAE")
    }

    @Test("Decisions are ready without a file")
    func decisionTakes() {
        let result = DecisionResult(
            question: "Which team?", type: "choice",
            scores: [.init(name: "billing", detail: "", probability: 0.97, score: 2.5),
                     .init(name: "technical", detail: "", probability: 0.03, score: -2.2)],
            answer: "billing", sources: [], model: "Jev", elapsedSeconds: 1, calibration: "Calibrated"
        )
        let request = DecisionRequest(question: "Which team?", options: [.init(name: "billing"), .init(name: "technical")])
        let messages = [
            ChatMessage(role: .user, content: request.messageText),
            ChatMessage(role: .assistant, blocks: [.toolCall(call("a", "Decision", result: result.json))]),
        ]
        let takes = GenerationTake.takes(from: messages, toolName: "Decision", isStreaming: false, requiresFile: false)
        #expect(takes.first?.phase == .ready)
        #expect(takes.first?.decision?.answer == "billing")
        #expect(takes.first?.decisionRequest == request)
    }

    @Test("A sent prompt takes over the stage; an opened thread shows its latest result")
    func selection() {
        let ready = GenerationTake(id: UUID(), prompt: "a", date: .now, toolCall: nil, attachments: [], reply: nil, phase: .ready)
        let failed = GenerationTake(id: UUID(), prompt: "b", date: .now, toolCall: nil, attachments: [], reply: nil, phase: .failed)
        var selection = StudioSelection()
        #expect(selection.take(in: [ready, failed])?.id == ready.id)
        selection.takesChanged(from: [ready.id], to: [ready.id, failed.id])
        #expect(selection.take(in: [ready, failed])?.id == failed.id)
        selection.selectedID = ready.id
        #expect(selection.take(in: [ready, failed])?.id == ready.id)
    }

    @Test("A take's parent is its recorded source, its attachment, or the newest image while running")
    func parents() {
        let first = GenerationTake(id: UUID(), prompt: "a", date: .now,
                                   toolCall: call("a", "ImageGeneration", result: #"{"savedPath":"/a.png"}"#),
                                   attachments: [], reply: nil, phase: .ready)
        let refined = GenerationTake(id: UUID(), prompt: "b", date: .now,
                                     toolCall: call("b", "ImageGeneration", result: #"{"savedPath":"/b.png","sourcePath":"/a.png"}"#),
                                     attachments: [], reply: nil, phase: .ready)
        let branched = GenerationTake(id: UUID(), prompt: "c", date: .now, toolCall: nil,
                                      attachments: [AttachmentInfo(name: "a.png", path: "/a.png", type: "image")],
                                      reply: nil, phase: .generating)
        let running = GenerationTake(id: UUID(), prompt: "d", date: .now, toolCall: nil, attachments: [], reply: nil, phase: .generating)
        let takes = [first, refined, branched, running]
        #expect(first.parentPath(in: takes, inheritsLatest: true) == nil)
        #expect(refined.parentPath(in: takes) == "/a.png")
        #expect(branched.parentPath(in: takes, inheritsLatest: true) == "/a.png")
        #expect(running.parentPath(in: takes, inheritsLatest: true) == "/b.png")
        #expect(running.parentPath(in: takes) == nil)
    }

    @Test("A clip's last frame is saved beside it")
    func lastFramePath() {
        #expect(StudioContinuation.lastFramePath(forVideoAt: "/v/2026-clip.mp4") == "/v/2026-clip-last-frame.png")
    }
}
