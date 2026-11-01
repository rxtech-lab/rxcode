import Foundation
import MLX
import MLXLMCommon
import struct RxCodeCore.DecisionRequest

extension NativeMLXInference {
    /// Uses the same segmented prompt and calibration as the GGUF scorer.
    /// Comparing raw yes/no logits is equivalent to comparing their logprobs.
    static func decisionScores(directory: URL, state: String, request: DecisionRequest,
                               readout: DecisionReadout, contextSize: Int) async throws -> [Double] {
        let container = try await load(directory: directory)
        var scorer = DecisionScorer(baseURL: directory, readout: readout, contextSize: contextSize)
        scorer.nativeTokenize = { text in
            await container.perform { context in
                context.tokenizer.encode(text: text, addSpecialTokens: false)
            }
        }
        scorer.nativeLogits = { tokens in
            try Task.checkCancellation()
            return try await container.perform { context in
                let yes = context.tokenizer.encode(text: readout.yesText, addSpecialTokens: false)
                let no = context.tokenizer.encode(text: readout.noText, addSpecialTokens: false)
                guard yes.count == 1, no.count == 1 else { throw DecisionScorer.ScoreError.malformed }
                let output = context.model(MLXArray(tokens).reshaped(1, tokens.count), cache: nil)
                let logits = output[0, tokens.count - 1]
                guard yes[0] >= 0, no[0] >= 0, yes[0] < logits.size, no[0] < logits.size else {
                    throw DecisionScorer.ScoreError.malformed
                }
                let a = logits[yes[0]].item(Float.self)
                let b = logits[no[0]].item(Float.self)
                guard a.isFinite, b.isFinite else { throw DecisionScorer.ScoreError.malformed }
                try Task.checkCancellation()
                return [yes[0]: Double(a), no[0]: Double(b)]
            }
        }
        return try await scorer.scores(state: state, request: request)
    }
}
