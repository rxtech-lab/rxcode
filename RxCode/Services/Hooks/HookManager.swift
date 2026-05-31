import Foundation
import os
import RxCodeCore

/// Registry + dispatcher for `Hook`s. Owned by `AppState`. Dispatch runs each
/// enabled hook **sequentially in registration order** (not concurrently):
/// hook cards are inserted one-by-one and the persisted "last hook" status row
/// is overwritten per hook, so concurrent runs would race the message list and
/// that row. Each event has its own typed `dispatch*` method so payloads stay
/// strongly typed end-to-end.
@MainActor
final class HookManager {
    private(set) var hooks: [any Hook] = []
    private let controller: any HookController
    private let logger = Logger(subsystem: "com.claudework", category: "HookManager")

    init(controller: any HookController) {
        self.controller = controller
    }

    func register(_ hook: any Hook) {
        hooks.append(hook)
    }

    private var enabledHooks: [any Hook] { hooks.filter(\.isEnabled) }

    // MARK: - Session lifecycle

    func dispatchProjectNewChatStart(_ payload: NewChatStartPayload) async {
        for hook in enabledHooks {
            _ = await hook.onProjectNewChatStart(payload, controller: controller)
        }
    }

    func dispatchSessionStart(_ payload: SessionStartPayload) async -> HookAggregateResult {
        var outcomes: [HookOutcome] = []
        for hook in enabledHooks {
            outcomes.append(await hook.onSessionStart(payload, controller: controller))
        }
        return HookAggregateResult.fold(outcomes)
    }

    func dispatchBeforeSessionEnd(_ payload: SessionEndPayload) async -> HookAggregateResult {
        var outcomes: [HookOutcome] = []
        for hook in enabledHooks {
            outcomes.append(await hook.beforeSessionEnd(payload, controller: controller))
        }
        return HookAggregateResult.fold(outcomes)
    }

    func dispatchAfterSessionEnd(_ payload: SessionEndPayload) async -> HookAggregateResult {
        var outcomes: [HookOutcome] = []
        for hook in enabledHooks {
            outcomes.append(await hook.afterSessionEnd(payload, controller: controller))
        }
        return HookAggregateResult.fold(outcomes)
    }

    // MARK: - Repository

    func dispatchRepositoryAdded(_ payload: RepositoryPayload) async {
        for hook in enabledHooks {
            _ = await hook.onRepositoryAdded(payload, controller: controller)
        }
    }

    func dispatchRepositoryCloned(_ payload: RepositoryPayload) async {
        for hook in enabledHooks {
            _ = await hook.onRepositoryCloned(payload, controller: controller)
        }
    }

    // MARK: - Questions & permissions

    func dispatchQuestionAsk(_ payload: QuestionAskPayload) async {
        for hook in enabledHooks {
            _ = await hook.onQuestionAsk(payload, controller: controller)
        }
    }

    func dispatchPermissionAsk(_ payload: PermissionAskPayload) async {
        for hook in enabledHooks {
            _ = await hook.onPermissionAsk(payload, controller: controller)
        }
    }

    func dispatchPermissionApprove(_ payload: PermissionDecisionPayload) async {
        for hook in enabledHooks {
            _ = await hook.onPermissionApprove(payload, controller: controller)
        }
    }

    func dispatchPermissionDenied(_ payload: PermissionDecisionPayload) async {
        for hook in enabledHooks {
            _ = await hook.onPermissionDenied(payload, controller: controller)
        }
    }

    // MARK: - Plan

    func dispatchPlanAccept(_ payload: PlanAcceptPayload) async {
        for hook in enabledHooks {
            _ = await hook.onPlanAccept(payload, controller: controller)
        }
    }

    func dispatchPlanReject(_ payload: PlanRejectPayload) async {
        for hook in enabledHooks {
            _ = await hook.onPlanReject(payload, controller: controller)
        }
    }

    // MARK: - Integrations

    func dispatchMCPDisconnected(_ payload: MCPDisconnectedPayload) async {
        for hook in enabledHooks {
            _ = await hook.onMCPDisconnected(payload, controller: controller)
        }
    }

    func dispatchCIFailed(_ payload: CIFailedPayload) async {
        for hook in enabledHooks {
            _ = await hook.onCIFailed(payload, controller: controller)
        }
    }

    func dispatchRemoteConfigChanged(_ payload: RemoteConfigChangedPayload) async {
        for hook in enabledHooks {
            _ = await hook.onRemoteConfigChanged(payload, controller: controller)
        }
    }
}
