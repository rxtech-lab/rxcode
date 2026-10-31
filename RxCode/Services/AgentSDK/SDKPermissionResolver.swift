import Foundation
import RxAgentCore
import RxCodeCore

/// Answers an SDK client's approval requests out of RxCode's existing
/// permission queue.
///
/// The SDK inverts RxCode's design: `PermissionServer` used to park a
/// continuation and wait for SwiftUI to call back into it, whereas an SDK
/// client simply awaits `resolve(_:)`. Both ends still want the same thing, so
/// this hands the request to `PermissionServer.requestDecision`, which is the
/// same entry point Codex and ACP approvals already use — one queue, one sheet,
/// one mobile fan-out, no second code path to keep in step.
struct SDKPermissionResolver: RxAgentCore.PermissionResolving {
    let server: PermissionServer
    /// RxCode's session key for the thread being approved. The SDK request
    /// carries an `AgentThreadID`, which the UI has no index for.
    let sessionKey: String

    func resolve(_ request: RxAgentCore.PermissionRequest) async -> RxAgentCore.PermissionDecision {
        // A question is answered, not approved: `requestDecision` keeps only
        // allow/deny, so the answers would be lost. The ask-user entry point
        // returns the `{questions, answers}` payload the card produced.
        if request.toolName == "AskUserQuestion" {
            let answers = await server.requestAskUserAnswers(
                toolUseId: request.id,
                sessionId: sessionKey,
                toolInput: request.toolInput.mapValues(AppJSON.init)
            )
            return answers.map { .allowWithInput(SDKJSON($0)) } ?? .deny
        }
        let decision = await server.requestDecision(
            toolUseId: request.id,
            sessionId: sessionKey,
            toolName: request.toolName,
            toolInput: request.toolInput.mapValues(AppJSON.init),
            mode: RxCodeCore.PermissionMode(request.mode)
        )
        return RxAgentCore.PermissionDecision(decision)
    }
}
