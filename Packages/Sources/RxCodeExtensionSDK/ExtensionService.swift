#if os(macOS)
import ExtensionFoundation
import Foundation
import os
@preconcurrency import XPC

public typealias ExtensionUsageHandler = @Sendable (ExtensionUsageIntegration, RxCodeHost) async throws -> ExtensionUsageSnapshot

/// Use as a headless configuration, or as the connection handler in an AppExtensionSceneConfiguration.
public enum ExtensionService {
    @MainActor public static func configuration(
        scenes: [String], test: @escaping @Sendable (String) -> String
    ) -> ConnectionHandler {
        configuration(scenes: scenes, test: test, fetchUsage: nil)
    }

    @MainActor public static func configuration(
        scenes: [String], test: @escaping @Sendable (String) -> String, fetchUsage: ExtensionUsageHandler?
    ) -> ConnectionHandler {
        let info = Bundle.main.infoDictionary
        let generation = (info?["RxCodeDevelopmentGeneration"] ?? info?["RxCodeSourceDigest"]) as? String
        let service = ServiceDispatcher(scenes: scenes, generation: generation, test: test, fetchUsage: fetchUsage)
        return ConnectionHandler { (incoming: XPCListener.IncomingSessionRequest) in
            incoming.accept { connection in ServicePeer(connection: connection, service: service) }
        }
    }
}

struct ServiceDispatcher: Sendable {
    let scenes: [String]
    let generation: String?
    let test: @Sendable (String) -> String
    let fetchUsage: ExtensionUsageHandler?

    func reply(to request: ExtensionRequest, host: RxCodeHost) async -> ExtensionResponse {
        do {
            try Task.checkCancellation()
            switch request.operation {
            case .hello:
                guard let generation, try request.decode(String.self) == generation else { throw ExtensionCallError.invalidRequest }
                return try ExtensionResponse(replyingTo: request, value: ExtensionHello(generation: generation, scenes: scenes))
            case .test:
                return try ExtensionResponse(replyingTo: request, value: test(request.decode(String.self)))
            case .fetchUsage:
                guard let fetchUsage else { throw ExtensionCallError.invalidRequest }
                let integration = try request.decode(ExtensionUsageIntegration.self)
                let snapshot = try await fetchUsage(integration, host)
                try Task.checkCancellation()
                guard snapshot.id == integration.id, snapshot.pluginID == integration.pluginID,
                      snapshot.projectID == integration.projectID else { throw ExtensionCallError.invalidRequest }
                return try ExtensionResponse(replyingTo: request, value: snapshot)
            default: throw ExtensionCallError.invalidRequest
            }
        } catch let error as ExtensionCallError { return ExtensionResponse(replyingTo: request, error: error) }
        catch let error as ExtensionUsageFailure { return ExtensionResponse(replyingTo: request, failure: error) }
        catch is CancellationError { return ExtensionResponse(replyingTo: request, error: .extensionBlocked) }
        catch { return ExtensionResponse(replyingTo: request, error: .invalidRequest) }
    }
}

private final class ServicePeer: XPCPeerHandler, Sendable {
    private struct State {
        var closed = false
        var worker: Task<Void, Never>?
    }
    private let service: ServiceDispatcher
    private let host: RxCodeHost
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "app.rxlab.extension.provider-reply")

    init(connection: XPCSession, service: ServiceDispatcher) {
        self.service = service
        host = RxCodeHost { [weak connection] request in
            guard let connection else { throw ExtensionCallError.extensionBlocked }
            let (stream, reply) = AsyncThrowingStream<ExtensionResponse, Error>.makeStream()
            defer { reply.finish() }
            try connection.send(request) { (result: Result<ExtensionResponse, Error>) in
                switch result {
                case .success(let value): reply.yield(value); reply.finish()
                case .failure(let error): reply.finish(throwing: error)
                }
            }
            var iterator = stream.makeAsyncIterator()
            guard let result = try await iterator.next() else { throw ExtensionCallError.extensionBlocked }
            try Task.checkCancellation()
            return result
        }
    }

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        guard message.expectsReply, let request = try? message.decode(as: ExtensionRequest.self) else { return nil }
        // XPC requires reply() inside the handoff closure. Moving that wait off the receiving queue
        // allows an asynchronous provider to call the host over the same session before it replies.
        return message.handoffReply(to: queue) { [self] in
            let finished = DispatchSemaphore(value: 0)
            let response = OSAllocatedUnfairLock<ExtensionResponse?>(initialState: nil)
            let started = state.withLock { state in
                guard !state.closed else { return false }
                state.worker = Task {
                    let value = await service.reply(to: request, host: host)
                    response.withLock { $0 = value }
                    finished.signal()
                }
                return true
            }
            if started { _ = finished.wait(timeout: .now() + 12) }
            let value = state.withLock { state in
                state.worker?.cancel()
                state.worker = nil
                return state.closed ? nil : response.withLock { $0 }
            }
            message.reply(value ?? ExtensionResponse(replyingTo: request, error: state.withLock { $0.closed } ? .extensionBlocked : .timeout))
        }
    }

    func handleCancellation(error: XPCRichError) {
        state.withLock {
            $0.closed = true
            $0.worker?.cancel()
        }
    }
}
#endif
