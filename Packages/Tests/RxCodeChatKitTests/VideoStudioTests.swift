import Foundation
import Testing
import RxCodeCore
@testable import RxCodeChatKit

@Suite("VideoStudio")
@MainActor
struct VideoStudioTests {
    private func videoCall(_ id: String, result: String?, isError: Bool = false) -> ToolCall {
        ToolCall(id: id, name: VideoGenerationProgress.toolName, result: result, isError: isError)
    }

    @Test("Each prompt pairs with the clip that answers it")
    func pairsPromptsWithClips() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "studio-\(UUID().uuidString).mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let messages = [
            ChatMessage(role: .user, content: "a red panda"),
            ChatMessage(role: .assistant, blocks: [.toolCall(videoCall("a", result: #"{"savedPath":"\#(file.path)","width":640,"height":384}"#))]),
            ChatMessage(role: .user, content: "a gone clip"),
            ChatMessage(role: .assistant, blocks: [.toolCall(videoCall("b", result: #"{"savedPath":"/nope/x.mp4"}"#))]),
            ChatMessage(role: .user, content: "broken"),
            ChatMessage(role: .assistant, blocks: [.toolCall(videoCall("c", result: #"{"displayError":"out of memory"}"#, isError: true))]),
            ChatMessage(role: .user, content: "rendering"),
            ChatMessage(role: .assistant, blocks: [.toolCall(videoCall("d", result: nil))]),
        ]
        let takes = VideoTake.takes(from: messages, isStreaming: true)
        #expect(takes.map(\.prompt) == ["a red panda", "a gone clip", "broken", "rendering"])
        #expect(takes.map(\.phase) == [.ready, .missing, .failed, .generating])
        #expect(takes[0].width == 640 && takes[0].height == 384, "\(takes[0].output)")
        #expect(takes[2].failureMessage == "out of memory")
    }

    @Test("An unanswered prompt is generating only while the turn streams")
    func pendingPrompt() {
        let messages = [ChatMessage(role: .user, content: "a cat")]
        #expect(VideoTake.takes(from: messages, isStreaming: true).first?.phase == .generating)
        #expect(VideoTake.takes(from: messages, isStreaming: false).first?.phase == .failed)
    }

    @Test("Sampler steps become a progress fraction")
    func progressFraction() {
        #expect(VideoProgressStatus.fraction(in: "Step 3/4 · 12.34s/it") == 0.75)
        #expect(VideoProgressStatus.fraction(in: "Generating…") == nil)
        #expect(VideoProgressStatus.fraction(in: nil) == nil)
    }
}
