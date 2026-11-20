import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

/// The single aggregate Live Activity push token registered by a paired
/// mobile. The desktop targets `update`/`end` pushes at `token`.
struct LiveActivityTokenRef: Codable, Sendable, Hashable {
    var activityID: String
    var token: String
}

/// Whether a paired mobile is currently reachable via the relay socket.
/// Resolved reactively from relay traffic — `unknown` until the first
/// inbound payload or `delivery_failed` notice settles it.
enum OnlineState: Sendable, Hashable {
    case unknown
    case online
    case offline
}

/// One paired mobile device. Persisted to
/// `~/Library/Application Support/RxCode/paired_devices.json`.
struct PairedDevice: Codable, Identifiable, Sendable, Hashable {
    var pubkeyHex: String
    var displayName: String
    var platform: String
    var pushProvider: String?
    var pushToken: String?
    var apnsToken: String?
    var apnsEnvironment: String?
    /// Device-wide Live Activity push-to-start token (iOS 17.2+). Lets the
    /// desktop spawn a job Live Activity remotely. Optional for wire/forward
    /// compatibility with paired-device files written before Live Activities.
    var liveActivityStartToken: String?
    /// Per-activity Live Activity update tokens, one per running job activity.
    var liveActivityTokens: [LiveActivityTokenRef]?
    var pairedAt: Date
    var lastSeen: Date?
    /// The relay server URL this device was paired through.
    var relayURL: String?

    /// Reactive online presence — not persisted. Always starts `.unknown` on
    /// launch; the first inbound/`delivery_failed` after `start()` resolves it.
    var onlineState: OnlineState = .unknown
    /// Wall-clock of the last `onlineState` change. Not persisted.
    var lastOnlineTransitionAt: Date? = nil
    /// Active transport path — not persisted. `.relay` until a direct link is
    /// promoted; drives the "Direct · LAN" / "Relay" badge.
    var activePath: ConnectionPathKind = .relay
    /// Measured direct-path handshake RTT in milliseconds — not persisted.
    var directRTTMillis: Int? = nil

    var id: String { pubkeyHex }

    /// Human-readable relay host for display (e.g. "relay.example.com").
    var relayDisplayName: String? {
        guard let urlString = relayURL,
              let url = URL(string: urlString),
              let host = url.host else { return nil }
        return host
    }

    // Persist only the long-lived fields — runtime presence (`onlineState`,
    // `lastOnlineTransitionAt`) is intentionally excluded so a launch always
    // begins in `.unknown` rather than restoring a possibly-stale value.
    enum CodingKeys: String, CodingKey {
        case pubkeyHex
        case displayName
        case platform
        case pushProvider
        case pushToken
        case apnsToken
        case apnsEnvironment
        case liveActivityStartToken
        case liveActivityTokens
        case pairedAt
        case lastSeen
        case relayURL
    }
}

/// Result of a pairing handshake propagated to the SwiftUI pairing sheet.
enum PairingOutcome: Sendable {
    case pending
    case received(PairRequestPayload)
    case accepted(PairedDevice)
    case cancelled
}

enum MobilePushError: LocalizedError {
    case missingDeviceToken
    case unknownPeer
    case invalidRelayURL
    case relayRejected(status: Int, body: String)
    case apnsRejected(status: Int, reason: String)
    case fcmRejected(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingDeviceToken:
            "This device has not registered a push token yet."
        case .unknownPeer:
            "This device is not available in the encrypted peer list."
        case .invalidRelayURL:
            "The relay URL cannot be converted to a push endpoint."
        case .relayRejected(let status, let body):
            "Relay rejected the push request (\(status)): \(body)"
        case .apnsRejected(let status, let reason):
            "APNs rejected the notification (\(status)): \(reason)"
        case .fcmRejected(let status, let reason):
            "FCM rejected the notification (\(status)): \(reason)"
        }
    }
}

/// A saved relay server configuration, stored in UserDefaults.
struct SavedRelayServer: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var addedAt: Date
    /// Whether this relay should be connected (user preference).
    var isEnabled: Bool

    /// Human-readable relay host for display (e.g. "relay.example.com").
    var displayHost: String? {
        guard let parsed = URL(string: url), let host = parsed.host else { return nil }
        return host
    }

    init(id: UUID = UUID(), name: String, url: String, addedAt: Date = .now, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.addedAt = addedAt
        self.isEnabled = isEnabled
    }
}

/// Connection state for a single relay server.
struct RelayConnectionInfo: Identifiable {
    let id: UUID  // matches SavedRelayServer.id
    var state: RelayClient.ConnectionState
}

struct PushRequest: Codable {
    let provider: String?
    let deviceToken: String
    let encryptedAlert: String
    let category: String?
    let collapseID: String?
    let apnsEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case deviceToken = "device_token"
        case encryptedAlert = "encrypted_alert"
        case category
        case collapseID = "collapse_id"
        case apnsEnvironment = "apns_environment"
    }
}

typealias APNsPushRequest = PushRequest

struct PushResponse: Codable {
    let provider: String?
    let statusCode: Int
    let reason: String?
    let apnsID: String?
    let apnsEnvironment: String?
    let messageID: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case statusCode = "status_code"
        case reason
        case apnsID = "apns_id"
        case apnsEnvironment = "apns_environment"
        case messageID = "message_id"
    }
}

typealias APNsPushResponse = PushResponse
