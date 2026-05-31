import Foundation

/// A unit of automation that reacts to lifecycle events. Many hooks can be
/// registered at once; each implements only the events it cares about (every
/// method has a no-op default). Each method receives a typed payload and the
/// `HookController` it can use to act on the thread / IDE.
///
/// `@MainActor` because hooks drive main-actor host state through the
/// controller. Out-of-process plugins are fronted by a single adapter hook that
/// serializes the (Codable) payloads — they do not conform to this protocol
/// directly.
@MainActor
public protocol Hook: AnyObject {
    /// Stable identifier for logging and de-duplication.
    var hookID: String { get }
    /// Whether this hook should receive events. Defaults to true.
    var isEnabled: Bool { get }

    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome
    func onSessionStart(_ payload: SessionStartPayload, controller: any HookController) async -> HookOutcome
    func beforeSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome
    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome
    func onRepositoryAdded(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome
    func onRepositoryCloned(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome
    func onQuestionAsk(_ payload: QuestionAskPayload, controller: any HookController) async -> HookOutcome
    func onPermissionAsk(_ payload: PermissionAskPayload, controller: any HookController) async -> HookOutcome
    func onPermissionApprove(_ payload: PermissionDecisionPayload, controller: any HookController) async -> HookOutcome
    func onPermissionDenied(_ payload: PermissionDecisionPayload, controller: any HookController) async -> HookOutcome
    func onPlanAccept(_ payload: PlanAcceptPayload, controller: any HookController) async -> HookOutcome
    func onPlanReject(_ payload: PlanRejectPayload, controller: any HookController) async -> HookOutcome
    func onMCPDisconnected(_ payload: MCPDisconnectedPayload, controller: any HookController) async -> HookOutcome
    func onCIFailed(_ payload: CIFailedPayload, controller: any HookController) async -> HookOutcome
    func onRemoteConfigChanged(_ payload: RemoteConfigChangedPayload, controller: any HookController) async -> HookOutcome
}

public extension Hook {
    var isEnabled: Bool { true }

    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onSessionStart(_ payload: SessionStartPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func beforeSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onRepositoryAdded(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onRepositoryCloned(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onQuestionAsk(_ payload: QuestionAskPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onPermissionAsk(_ payload: PermissionAskPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onPermissionApprove(_ payload: PermissionDecisionPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onPermissionDenied(_ payload: PermissionDecisionPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onPlanAccept(_ payload: PlanAcceptPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onPlanReject(_ payload: PlanRejectPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onMCPDisconnected(_ payload: MCPDisconnectedPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onCIFailed(_ payload: CIFailedPayload, controller: any HookController) async -> HookOutcome { .ignored }
    func onRemoteConfigChanged(_ payload: RemoteConfigChangedPayload, controller: any HookController) async -> HookOutcome { .ignored }
}
