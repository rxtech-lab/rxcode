#if os(macOS)
import Foundation

public struct ExtensionSceneContext: Codable, Sendable {
    public let projectPath: String
    public let generation: String
    public let snapshot: Data?
    public let configuration: Data?

    public init(projectPath: String, generation: String, snapshot: Data? = nil, configuration: Data? = nil) {
        self.projectPath = projectPath
        self.generation = generation
        self.snapshot = snapshot
        self.configuration = configuration
    }
}

@objc(RxCodeExtensionSceneV2)
public protocol ExtensionSceneEndpoint {
    func applyContext(_ data: Data, reply: @escaping (Bool) -> Void)
}

@objc(RxCodeExtensionHostV2)
public protocol ExtensionSceneHostEndpoint {
    func call(_ data: Data, reply: @escaping (Data?) -> Void)
}

/// Export one endpoint per scene so windows keep independent contexts and broker connections.
public final class ExtensionSceneConnection: NSObject, ExtensionSceneEndpoint {
    private let apply: @Sendable (ExtensionSceneContext, RxCodeHost) -> Void
    private let host: RxCodeHost

    public static func accept(_ connection: NSXPCConnection,
                              apply: @escaping @Sendable (ExtensionSceneContext, RxCodeHost) -> Void) -> Bool {
        connection.remoteObjectInterface = NSXPCInterface(with: ExtensionSceneHostEndpoint.self)
        connection.exportedInterface = NSXPCInterface(with: ExtensionSceneEndpoint.self)
        connection.exportedObject = ExtensionSceneConnection(sender: SceneSender(connection: connection), apply: apply)
        connection.resume()
        return true
    }

    private init(sender: SceneSender, apply: @escaping @Sendable (ExtensionSceneContext, RxCodeHost) -> Void) {
        self.apply = apply
        host = RxCodeHost { try await sender.send($0) }
    }

    public func applyContext(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard let context = try? JSONDecoder().decode(ExtensionSceneContext.self, from: data) else {
            reply(false)
            return
        }
        apply(context, host)
        reply(true)
    }
}

private final class SceneSender: @unchecked Sendable {
    weak var connection: NSXPCConnection?
    init(connection: NSXPCConnection) { self.connection = connection }

    func send(_ request: ExtensionRequest) async throws -> ExtensionResponse {
        guard let connection else { throw ExtensionCallError.extensionBlocked }
        let bytes = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) }
            guard let proxy = proxy as? ExtensionSceneHostEndpoint else {
                continuation.resume(throwing: ExtensionCallError.invalidRequest)
                return
            }
            proxy.call(bytes) { data in
                guard let data, let reply = try? JSONDecoder().decode(ExtensionResponse.self, from: data) else {
                    continuation.resume(throwing: ExtensionCallError.invalidRequest)
                    return
                }
                continuation.resume(returning: reply)
            }
        }
    }
}
#endif
