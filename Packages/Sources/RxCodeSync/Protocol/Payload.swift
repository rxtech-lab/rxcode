import Foundation
import RxCodeCore

/// All plaintext payloads exchanged between paired devices.
///
/// Encoded as a tagged JSON object with `type` as the discriminator so adding
/// new cases stays forward-compatible. Unknown cases decode to
/// `.unknown(type:)` rather than failing the entire envelope decode.
public enum Payload: Sendable {
    case pairRequest(PairRequestPayload)
    case pairAck(PairAckPayload)
    case apnsToken(APNsTokenPayload)
    case requestSnapshot(RequestSnapshotPayload)
    case snapshot(SnapshotPayload)
    case sessionUpdate(SessionUpdatePayload)
    case subscribeSession(SubscribeSessionPayload)
    case userMessage(UserMessagePayload)
    case newSessionRequest(NewSessionRequestPayload)
    case notification(NotificationPayload)
    case permissionRequest(PermissionRequestPayload)
    case permissionResponse(PermissionResponsePayload)
    case ping(PingPayload)
    case pong(PongPayload)
    case unknown(type: String)
}

// MARK: - Wire structs

public struct PairRequestPayload: Codable, Sendable {
    public let mobilePubkeyHex: String
    public let displayName: String
    public let platform: String
    public let appVersion: String
    public init(mobilePubkeyHex: String, displayName: String, platform: String, appVersion: String) {
        self.mobilePubkeyHex = mobilePubkeyHex
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct PairAckPayload: Codable, Sendable {
    public let accepted: Bool
    public let desktopName: String
    public let reason: String?
    public init(accepted: Bool, desktopName: String, reason: String? = nil) {
        self.accepted = accepted
        self.desktopName = desktopName
        self.reason = reason
    }
}

public struct APNsTokenPayload: Codable, Sendable {
    public let tokenHex: String
    public let environment: String
    public init(tokenHex: String, environment: String) {
        self.tokenHex = tokenHex
        self.environment = environment
    }
}

public struct RequestSnapshotPayload: Codable, Sendable {
    public let activeSessionID: String?
    public init(activeSessionID: String? = nil) {
        self.activeSessionID = activeSessionID
    }
}

public struct SnapshotPayload: Codable, Sendable {
    public let projects: [Project]
    public let sessions: [SessionSummary]
    public let activeSessionID: String?
    public let activeSessionMessages: [ChatMessage]?
    public init(
        projects: [Project],
        sessions: [SessionSummary],
        activeSessionID: String? = nil,
        activeSessionMessages: [ChatMessage]? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.activeSessionMessages = activeSessionMessages
    }
}

public struct SessionSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let projectId: UUID
    public let title: String
    public let updatedAt: Date
    public let isPinned: Bool
    public let isArchived: Bool
    public init(
        id: String,
        projectId: UUID,
        title: String,
        updatedAt: Date,
        isPinned: Bool,
        isArchived: Bool
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

public struct SessionUpdatePayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case messageAppended
        case messageUpdated
        case streamingStarted
        case streamingFinished
        case statusChanged
    }
    public let sessionID: String
    public let kind: Kind
    public let message: ChatMessage?
    public let isStreaming: Bool?
    public init(
        sessionID: String,
        kind: Kind,
        message: ChatMessage? = nil,
        isStreaming: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.message = message
        self.isStreaming = isStreaming
    }
}

public struct SubscribeSessionPayload: Codable, Sendable {
    public let sessionID: String?
    public init(sessionID: String?) { self.sessionID = sessionID }
}

public struct UserMessagePayload: Codable, Sendable {
    public let clientMessageID: UUID
    public let sessionID: String
    public let text: String
    public init(clientMessageID: UUID = UUID(), sessionID: String, text: String) {
        self.clientMessageID = clientMessageID
        self.sessionID = sessionID
        self.text = text
    }
}

public struct NewSessionRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let initialText: String?
    public init(clientRequestID: UUID = UUID(), projectID: UUID, initialText: String? = nil) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.initialText = initialText
    }
}

public struct NotificationPayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case responseComplete
        case permissionNeeded
        case questionNeeded
        case mcpDisconnected
        case generic
    }
    public let kind: Kind
    public let title: String
    public let body: String
    public let sessionID: String?
    public let projectID: UUID?
    public init(
        kind: Kind,
        title: String,
        body: String,
        sessionID: String? = nil,
        projectID: UUID? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.projectID = projectID
    }
}

public struct PermissionRequestPayload: Codable, Sendable {
    public let requestID: String
    public let toolName: String
    public let toolInputJSON: String
    public let sessionID: String?
    public init(requestID: String, toolName: String, toolInputJSON: String, sessionID: String?) {
        self.requestID = requestID
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.sessionID = sessionID
    }
}

public struct PermissionResponsePayload: Codable, Sendable {
    public let requestID: String
    public let allow: Bool
    public let denyReason: String?
    public init(requestID: String, allow: Bool, denyReason: String? = nil) {
        self.requestID = requestID
        self.allow = allow
        self.denyReason = denyReason
    }
}

public struct PingPayload: Codable, Sendable {
    public let t: Date
    public init(t: Date = .now) { self.t = t }
}

public struct PongPayload: Codable, Sendable {
    public let t: Date
    public init(t: Date = .now) { self.t = t }
}

// MARK: - Codable

extension Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    enum TypeKey: String {
        case pairRequest = "pair_request"
        case pairAck = "pair_ack"
        case apnsToken = "apns_token"
        case requestSnapshot = "request_snapshot"
        case snapshot
        case sessionUpdate = "session_update"
        case subscribeSession = "subscribe_session"
        case userMessage = "user_message"
        case newSessionRequest = "new_session_request"
        case notification
        case permissionRequest = "permission_request"
        case permissionResponse = "permission_response"
        case ping
        case pong
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = TypeKey(rawValue: rawType) else {
            self = .unknown(type: rawType)
            return
        }
        switch kind {
        case .pairRequest: self = .pairRequest(try container.decode(PairRequestPayload.self, forKey: .data))
        case .pairAck: self = .pairAck(try container.decode(PairAckPayload.self, forKey: .data))
        case .apnsToken: self = .apnsToken(try container.decode(APNsTokenPayload.self, forKey: .data))
        case .requestSnapshot: self = .requestSnapshot(try container.decode(RequestSnapshotPayload.self, forKey: .data))
        case .snapshot: self = .snapshot(try container.decode(SnapshotPayload.self, forKey: .data))
        case .sessionUpdate: self = .sessionUpdate(try container.decode(SessionUpdatePayload.self, forKey: .data))
        case .subscribeSession: self = .subscribeSession(try container.decode(SubscribeSessionPayload.self, forKey: .data))
        case .userMessage: self = .userMessage(try container.decode(UserMessagePayload.self, forKey: .data))
        case .newSessionRequest: self = .newSessionRequest(try container.decode(NewSessionRequestPayload.self, forKey: .data))
        case .notification: self = .notification(try container.decode(NotificationPayload.self, forKey: .data))
        case .permissionRequest: self = .permissionRequest(try container.decode(PermissionRequestPayload.self, forKey: .data))
        case .permissionResponse: self = .permissionResponse(try container.decode(PermissionResponsePayload.self, forKey: .data))
        case .ping: self = .ping(try container.decode(PingPayload.self, forKey: .data))
        case .pong: self = .pong(try container.decode(PongPayload.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairRequest(let p): try container.encode(TypeKey.pairRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pairAck(let p): try container.encode(TypeKey.pairAck.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .apnsToken(let p): try container.encode(TypeKey.apnsToken.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .requestSnapshot(let p): try container.encode(TypeKey.requestSnapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .snapshot(let p): try container.encode(TypeKey.snapshot.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .sessionUpdate(let p): try container.encode(TypeKey.sessionUpdate.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .subscribeSession(let p): try container.encode(TypeKey.subscribeSession.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .userMessage(let p): try container.encode(TypeKey.userMessage.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .newSessionRequest(let p): try container.encode(TypeKey.newSessionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .notification(let p): try container.encode(TypeKey.notification.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionRequest(let p): try container.encode(TypeKey.permissionRequest.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .permissionResponse(let p): try container.encode(TypeKey.permissionResponse.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .ping(let p): try container.encode(TypeKey.ping.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(TypeKey.pong.rawValue, forKey: .type); try container.encode(p, forKey: .data)
        case .unknown(let type): try container.encode(type, forKey: .type)
        }
    }
}
