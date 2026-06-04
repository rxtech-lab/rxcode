import Foundation
import RxCodeCore

/// Runs the user-configured bash hook profiles. Maps the three persisted
/// `HookTrigger` cases onto the new lifecycle events:
///   - `.beforeSessionStart` → `onSessionStart`
///   - `.beforeSessionStop`  → `beforeSessionEnd`
///   - `.afterSessionStop`   → `afterSessionEnd`
///
/// For each matching profile it inserts a live status card (spinner → result),
/// runs the command headless via `HookService`, persists the card as the
/// session's "last hook" so it survives reload, and returns the combined stdout
/// (with a non-zero exit surfaced as `isError`) so a start hook's output is
/// injected into the agent context and a failing stop hook can auto-continue.
@MainActor
final class UserAddedHook: Hook {
    let hookID = "builtin.userAddedHook"

    func onSessionStart(_ payload: SessionStartPayload, controller: any HookController) async -> HookOutcome {
        await run(trigger: .beforeSessionStart, project: payload.project, sessionKey: payload.sessionKey, controller: controller)
    }

    func beforeSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        await run(trigger: .beforeSessionStop, project: payload.project, sessionKey: payload.sessionKey, controller: controller)
    }

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        await run(trigger: .afterSessionStop, project: payload.project, sessionKey: payload.sessionKey, controller: controller)
    }

    private func run(
        trigger: HookTrigger,
        project: Project,
        sessionKey: String,
        controller: any HookController
    ) async -> HookOutcome {
        // Only command hooks run here; built-in actions (code review, commit &
        // push) are handled by their own dedicated hooks.
        let hooks = await controller.enabledHookProfiles(projectId: project.id, trigger: trigger)
            .filter { $0.action == .command }
        guard !hooks.isEmpty else { return .ignored }

        var combined: [String] = []
        var anyError = false
        for hook in hooks {
            let handle = controller.insertCard(
                sessionKey: sessionKey,
                toolName: AppState.hookToolName(for: hook),
                input: [
                    "name": .string(hook.name),
                    "trigger": .string(hook.trigger.displayName),
                ]
            )

            let result = await HookService.run(hook, project: project)
            let displayOutput = result.output.isEmpty ? "(no output)" : result.output

            controller.completeCard(handle, sessionKey: sessionKey, result: displayOutput, isError: result.isError)

            // Persist as the session's "last hook" so the synthetic card can be
            // rebuilt on reload. Each hook overwrites the prior row, so the most
            // recent hook (across triggers) is the one that survives.
            controller.persistHookStatus(
                sessionKey: sessionKey,
                toolId: handle.toolId,
                name: hook.name,
                trigger: hook.trigger.displayName,
                output: displayOutput,
                isError: result.isError,
                isComplete: true
            )

            if result.isError { anyError = true }
            if !result.output.isEmpty {
                combined.append("### Hook: \(hook.name)\n\(result.output)")
            }
        }

        return .output(combined.joined(separator: "\n\n"), isError: anyError)
    }
}
