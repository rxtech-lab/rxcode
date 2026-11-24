import Foundation

/// The operation and JSON payload on a single host or extension RPC.
public struct ExtensionRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case hello, fetchUsage, test
        case filesRead = "files.read", filesList = "files.list"
        case netFetch = "net.fetch", storageGet = "storage.get", storageSet = "storage.set"
        case contactsQuery = "contacts.query", vaultRead = "vault.read", vaultCreate = "vault.create"
        case localUsage = "usage.local.summary", rateLimits = "rateLimits.read"
    }

    public let id: UUID
    public let operation: Operation
    public let payload: Data

    public init<T: Encodable>(_ operation: Operation, _ value: T) throws {
        id = UUID()
        self.operation = operation
        payload = try JSONEncoder().encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

public enum ExtensionCallError: String, Error, Codable, Sendable {
    case permissionDenied, permissionPending, invalidRequest, timeout, extensionBlocked, credentialUnavailable
}

/// A provider can describe a failed refresh without replacing the last successful snapshot.
public struct ExtensionUsageFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = String(message.prefix(1024)) }
    public var errorDescription: String? { message }
}

public struct ExtensionResponse: Codable, Sendable {
    public let id: UUID
    public let result: ResultPayload

    public enum ResultPayload: Codable, Sendable {
        case success(Data)
        case failure(ExtensionCallError)
        case providerFailure(String)
    }

    public init<T: Encodable>(replyingTo request: ExtensionRequest, value: T) throws {
        id = request.id
        result = .success(try JSONEncoder().encode(value))
    }

    public init(replyingTo request: ExtensionRequest, error: ExtensionCallError) {
        id = request.id
        result = .failure(error)
    }

    public init(replyingTo request: ExtensionRequest, failure: ExtensionUsageFailure) {
        id = request.id
        result = .providerFailure(failure.message)
    }

    public func decode<T: Decodable>(_ type: T.Type, for request: ExtensionRequest) throws -> T {
        guard id == request.id else { throw ExtensionCallError.invalidRequest }
        switch result {
        case .success(let data): return try JSONDecoder().decode(type, from: data)
        case .failure(let error): throw error
        case .providerFailure(let message): throw ExtensionUsageFailure(message)
        }
    }
}

/// One client is bound to the transport of a single activated extension.
public struct RxCodeHost: Sendable {
    private let send: @Sendable (ExtensionRequest) async throws -> ExtensionResponse

    public init(send: @escaping @Sendable (ExtensionRequest) async throws -> ExtensionResponse) {
        self.send = send
    }

    public func call<Input: Encodable, Output: Decodable>(
        _ operation: ExtensionRequest.Operation, _ input: Input, returning: Output.Type
    ) async throws -> Output {
        let request = try ExtensionRequest(operation, input)
        return try await send(request).decode(returning, for: request)
    }
}

public struct ExtensionHello: Codable, Sendable {
    public let generation: String
    public let scenes: [String]

    public init(generation: String, scenes: [String]) {
        self.generation = generation
        self.scenes = scenes
    }
}
