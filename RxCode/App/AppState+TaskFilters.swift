#if os(macOS)
import Foundation
import os
import RxCodeCore

/// Agent-written Swift filters on project views. See `TaskFilterScript` for
/// the script contract and `TaskFilterScriptEvaluator` for how it runs.
extension AppState {
    /// Asks the task suggestion agent for a filter script matching
    /// `requirement`. Returns the Swift source, or `nil` when the agent gave
    /// no usable answer.
    func generateTaskFilterScript(requirement: String, projectId: UUID) async -> String? {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = TaskFilterScript.prompt(requirement: trimmed, board: taskBoard(for: projectId))
        guard let raw = await runTaskAgentCompletion(prompt: prompt, projectId: projectId, verbatim: true) else {
            logger.warning("[Tasks] no filter script response")
            return nil
        }
        return TaskFilterScript.extractSwift(from: raw)
    }

    func compileTaskFilterScript(_ script: String) async -> TaskFilterScriptEvaluator.CompileResult {
        await taskFilterEvaluator.compile(script: script)
    }

    /// Runs `script` over every task and story on the project's board.
    func evaluateTaskFilterScript(_ script: String, projectId: UUID) async -> TaskFilterScriptEvaluator.Outcome {
        let input = TaskFilterScript.input(for: taskBoard(for: projectId))
        return await taskFilterEvaluator.evaluate(script: script, input: input)
    }
}
#endif
