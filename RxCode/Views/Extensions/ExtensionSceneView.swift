import ExtensionFoundation
import ExtensionKit
import RxCodeCore
import RxCodeExtensionSDK
import SwiftUI

struct ExtensionSceneView: View {
    let activated: ActivatedExtension
    let scene: String
    let snapshot: Data?
    let configuration: Data?
    let integration: UsageIntegration?
    let state: AppState?
    @State private var interaction = SceneInteraction()

    init(extension activated: ActivatedExtension, scene: String, snapshot: Data? = nil, configuration: Data? = nil,
         integration: UsageIntegration? = nil, appState: AppState? = nil) {
        self.integration = integration
        self.state = appState
        self.activated = activated
        self.scene = scene
        self.snapshot = snapshot
        self.configuration = configuration
    }

    var body: some View {
        if activated.manifest.contributes.sceneIDs.contains(scene),
           AgentExtensionRuntime.shared.panels.contains(where: { $0.broker === activated.broker }) {
            SceneController(activated: activated, scene: scene, interaction: interaction, integration: integration, state: state,
                            payload: .init(projectPath: activated.workspace.path, generation: activated.generation,
                                           snapshot: snapshot, configuration: configuration))
                .overlay(alignment: .bottom) {
                    if let action = interaction.action {
                        HStack {
                            Text(verbatim: action.target)
                                .lineLimit(2)
                            Button(action.title) { interaction.finish(true) }
                            Button("Cancel", role: .cancel) { interaction.finish(false) }
                        }
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                    }
                }
                .id(SceneKey(broker: ObjectIdentifier(activated.broker), scene: scene, integration: integration?.id, account: integration?.account, resource: integration?.resource))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Extension unavailable", systemImage: "puzzlepiece.extension")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SceneKey: Hashable {
    let broker: ObjectIdentifier
    let scene: String
    let integration: UUID?
    let account: String?
    let resource: String?
}

private struct SceneController: NSViewControllerRepresentable {
    let activated: ActivatedExtension
    let scene: String
    let interaction: SceneInteraction
    let integration: UsageIntegration?
    let state: AppState?
    let payload: ExtensionSceneContext

    func makeCoordinator() -> Coordinator { Coordinator(activated: activated, interaction: ["inspector", "settings"].contains(scene) ? interaction : nil, integration: integration, state: state) }

    func makeNSViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.delegate = context.coordinator
        controller.configuration = .init(appExtension: activated.identity, sceneID: scene)
        return controller
    }

    func updateNSViewController(_ controller: EXHostViewController, context: Context) {
        context.coordinator.update(payload)
    }

    static func dismantleNSViewController(_ controller: EXHostViewController, coordinator: Coordinator) {
        coordinator.close()
        controller.delegate = nil
        controller.configuration = nil
    }

    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        let activated: ActivatedExtension
        var connection: NSXPCConnection?
        var payload: Data?

        let interaction: SceneInteraction?
        let integration: UsageIntegration?
        weak var state: AppState?
        private var boundBroker: ExtensionBroker?

        init(activated: ActivatedExtension, interaction: SceneInteraction?, integration: UsageIntegration?, state: AppState?) {
            self.integration = integration
            self.state = state
            self.activated = activated
            self.interaction = interaction
        }

        func update(_ value: ExtensionSceneContext) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let bytes = try? encoder.encode(value), bytes != payload else { return }
            payload = bytes
            send()
        }

        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            guard let connection = try? viewController.makeXPCConnection() else { return }
            let hash = activated.codeHash.map { String(format: "%02x", $0) }.joined()
            var requirement = "cdhash H\"\(hash)\""
            if activated.requiresDeveloperID {
                requirement += #" and anchor apple generic and certificate leaf[subject.OU] = "T7GYB573Y6""#
            }
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: ExtensionSceneEndpoint.self)
            connection.exportedInterface = NSXPCInterface(with: ExtensionSceneHostEndpoint.self)
            if let integration {
                guard let state, let broker = try? activated.broker.bindUsageScene(to: integration, appState: state) else {
                    connection.invalidate()
                    return
                }
                boundBroker = broker
            }
            connection.exportedObject = SceneHostEndpoint(activated: activated, interaction: interaction, broker: boundBroker ?? activated.broker)
            self.connection = connection
            connection.resume()
            send()
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) { close() }

        func close() {
            boundBroker?.block()
            boundBroker = nil
            interaction?.finish(false)
            connection?.invalidate()
            connection = nil
        }

        private func send() {
            guard let payload, let connection else { return }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in connection.invalidate() }
            (proxy as? ExtensionSceneEndpoint)?.applyContext(payload) { accepted in
                if !accepted { connection.invalidate() }
            }
        }
    }
}

private final class SceneHostEndpoint: NSObject, ExtensionSceneHostEndpoint {
    let activated: ActivatedExtension
    let interaction: SceneInteraction?
    let broker: ExtensionBroker
    init(activated: ActivatedExtension, interaction: SceneInteraction?, broker: ExtensionBroker) {
        self.broker = broker
        self.activated = activated
        self.interaction = interaction
    }

    nonisolated func call(_ data: Data, reply: @escaping (Data?) -> Void) {
        guard data.count <= 2 * 1024 * 1024,
              let request = try? JSONDecoder().decode(ExtensionRequest.self, from: data) else { reply(nil); return }
        Task { @MainActor in
            let vaultPermission: ExtensionPermission.ID?
            switch request.operation {
            case .vaultRead: vaultPermission = .vaultRead
            case .vaultCreate: vaultPermission = .vaultCreate
            default: vaultPermission = nil
            }
            var userInitiated = interaction != nil && vaultPermission == nil
            if let interaction, let vaultPermission,
               let permission = activated.manifest.permissions.first(where: { $0.id == vaultPermission }),
               ExtensionPermissionStore.shared.decision(for: permission, identity: activated.permissionIdentity) == .confirm {
                guard await interaction.confirm(request) else {
                    reply(try? JSONEncoder().encode(ExtensionResponse(replyingTo: request, error: .permissionPending)))
                    return
                }
                userInitiated = true
            }
            let result = await broker.handle(request, origin: userInitiated ? .userInitiated : .background,
                                                       permissionsReviewed: true)
            reply(try? JSONEncoder().encode(result))
        }
    }
}

/// A trusted host button authorizes this exact vault call. An extension's timer or its own UI
/// cannot present passkey prompts, and closing the scene declines any pending request.
@MainActor @Observable
private final class SceneInteraction {
    struct Action {
        let title: LocalizedStringKey
        let target: String
    }
    var action: Action?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    func confirm(_ request: ExtensionRequest) async -> Bool {
        guard action == nil, let fields = try? request.decode([String: String].self),
              let environment = fields["environment"], !environment.isEmpty else { return false }
        let target = [environment, fields["filename"]].compactMap { $0 }.joined(separator: " / ")
        action = Action(title: request.operation == .vaultRead ? "Read Secret" : "Create Secret", target: target)
        timer = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            finish(false)
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ approved: Bool) {
        timer?.cancel()
        timer = nil
        action = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }
}
