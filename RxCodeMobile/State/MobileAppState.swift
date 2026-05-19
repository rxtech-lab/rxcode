import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync

/// Single source of truth for the mobile app. Owns the `SyncClient`, the
/// decoded projects/sessions/messages mirrored from the paired desktop, and
/// the pairing flow.
@MainActor
final class MobileAppState: ObservableObject {
    enum PairingStatus: Equatable {
        case idle
        case inProgress
        case failed(String)
    }

    @Published var isPaired: Bool = false
    @Published var pairedDesktopName: String = ""
    @Published var pairedDesktopPubkey: String = ""
    @Published var connectionState: RelayClient.ConnectionState = .disconnected
    @Published var relayURL: URL
    @Published var pairingStatus: PairingStatus = .idle

    @Published var projects: [Project] = []
    @Published var sessions: [SessionSummary] = []
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var activeSessionID: String?
    @Published var pendingPermission: PermissionRequestPayload?

    private let identity: DeviceIdentity
    private let client: SyncClient
    private var eventTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var apnsTokenHex: String?
    private var apnsEnvironment: String?

    static let pairingTimeoutSeconds: UInt64 = 25

    init() {
        let stored = UserDefaults.standard.string(forKey: "mobileSync.relayURL")
        let initial = URL(string: stored ?? Self.defaultRelayURLString)
            ?? URL(string: Self.defaultRelayURLString)!
        self.relayURL = initial
        do {
            // Shared access group lets the Notification Service Extension
            // read the private key for decrypting APNs alerts. The bare group
            // suffix is matched against the (already-expanded) entitlement —
            // never pass the literal `$(AppIdentifierPrefix)…` here, that's a
            // build-time substitution and is meaningless at runtime.
            self.identity = try DeviceIdentity.loadOrCreate(
                accessGroup: Self.keychainAccessGroup
            )
        } catch {
            fatalError("Failed to load mobile device identity: \(error)")
        }
        self.client = SyncClient(identity: identity, relayURL: initial)
        loadPairedDesktop()
    }

    /// Bare suffix as declared (post-`$(AppIdentifierPrefix)`) in
    /// `RxCodeMobile.entitlements` and the NSE entitlements file.
    static let keychainAccessGroupSuffix = "app.rxlab.rxcodemobile.shared"

    /// Fully-qualified access group resolved at runtime (e.g.
    /// `T7GYB573Y6.app.rxlab.rxcodemobile.shared`). iOS requires the prefixed
    /// form when calling `SecItem*`.
    static var keychainAccessGroup: String {
        DeviceIdentity.resolveAccessGroup(suffix: keychainAccessGroupSuffix)
    }

    static var defaultRelayURLString: String {
        #if DEBUG
        return "ws://localhost:8787/ws"
        #else
        return "wss://relay.rxlab.app/ws"
        #endif
    }

    var localPublicKeyHex: String { identity.publicKeyHex }

    func start() {
        Task { @MainActor in
            if !pairedDesktopPubkey.isEmpty {
                try? await client.addPeer(pairedDesktopPubkey)
            }
            await client.start()
            let events = await client.events()
            eventTask?.cancel()
            eventTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await event in events {
                    self.handle(event)
                }
            }
            // Re-request snapshot on every (re)start so we don't show stale state.
            if isPaired {
                let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
                try? await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
                await reportAPNsTokenIfPending()
            }
        }
    }

    // MARK: - Pairing

    func pair(with token: PairingToken, displayName: String) async {
        guard !token.isExpired,
              let desktopKey = token.desktopPublicKey else {
            pairingStatus = .failed("Invalid or expired pairing code.")
            return
        }
        pairingStatus = .inProgress
        let desktopHex = token.desktopPubkeyHex
        try? await client.addPeer(desktopHex)
        // Persist the relay URL we just learned from the QR.
        if let url = URL(string: token.relayURL) {
            UserDefaults.standard.set(url.absoluteString, forKey: "mobileSync.relayURL")
            relayURL = url
        }
        let req = PairRequestPayload(
            mobilePubkeyHex: identity.publicKeyHex,
            displayName: displayName,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
        do {
            try await client.send(.pairRequest(req), toHex: desktopHex)
        } catch {
            pairingStatus = .failed("Couldn't reach the relay. Check your network and try again.")
            return
        }
        _ = desktopKey  // silence unused
        startPairingTimeout()
    }

    func cancelPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        if !isPaired { pairingStatus = .idle }
    }

    func dismissPairingError() {
        if case .failed = pairingStatus { pairingStatus = .idle }
    }

    private func startPairingTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            let seconds = Self.pairingTimeoutSeconds
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard !self.isPaired else { return }
                self.pairingStatus = .failed(
                    "Your Mac didn't respond. Make sure RxCode is open and connected, then try again."
                )
            }
        }
    }

    // MARK: - User intents

    func sendUserMessage(_ text: String, sessionID: String) async {
        guard isPaired else { return }
        let payload = UserMessagePayload(sessionID: sessionID, text: text)
        try? await client.send(.userMessage(payload), toHex: pairedDesktopPubkey)
    }

    func requestNewSession(projectID: UUID, initialText: String? = nil) async {
        guard isPaired else { return }
        let payload = NewSessionRequestPayload(projectID: projectID, initialText: initialText)
        try? await client.send(.newSessionRequest(payload), toHex: pairedDesktopPubkey)
    }

    func subscribe(to sessionID: String?) async {
        activeSessionID = sessionID
        guard isPaired else { return }
        let payload = SubscribeSessionPayload(sessionID: sessionID)
        try? await client.send(.subscribeSession(payload), toHex: pairedDesktopPubkey)
    }

    func respondToPermission(allow: Bool, denyReason: String? = nil) async {
        guard let pending = pendingPermission else { return }
        let payload = PermissionResponsePayload(
            requestID: pending.requestID,
            allow: allow,
            denyReason: denyReason
        )
        try? await client.send(.permissionResponse(payload), toHex: pairedDesktopPubkey)
        pendingPermission = nil
    }

    func reportAPNsToken(hex: String, environment: String) {
        apnsTokenHex = hex
        apnsEnvironment = environment
        Task { await reportAPNsTokenIfPending() }
    }

    func unpair() async {
        if !pairedDesktopPubkey.isEmpty {
            await client.removePeer(pairedDesktopPubkey)
        }
        pairedDesktopPubkey = ""
        pairedDesktopName = ""
        isPaired = false
        savePairedDesktop()
        try? DeviceIdentity.reset(
            accessGroup: Self.keychainAccessGroup
        )
    }

    // MARK: - Inbound events

    private func handle(_ event: RelayClient.Event) {
        switch event {
        case .stateChanged(let state):
            connectionState = state
            if case .connected = state, isPaired {
                Task { await self.requestSnapshot() }
            }
        case .deliveryFailed:
            break
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    private func handleInbound(_ inbound: RelayClient.Inbound) {
        switch inbound.payload {
        case .pairAck(let ack):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            if ack.accepted {
                pairedDesktopPubkey = inbound.fromHex
                pairedDesktopName = ack.desktopName
                isPaired = true
                pairingStatus = .idle
                savePairedDesktop()
                Task {
                    await self.requestSnapshot()
                    await self.reportAPNsTokenIfPending()
                }
            } else {
                isPaired = false
                pairingStatus = .failed("Your Mac declined the pairing request.")
            }
        case .snapshot(let snap):
            projects = snap.projects
            sessions = snap.sessions
            if let active = snap.activeSessionID, let messages = snap.activeSessionMessages {
                messagesBySession[active] = messages
                activeSessionID = active
            }
        case .sessionUpdate(let update):
            applySessionUpdate(update)
        case .permissionRequest(let req):
            pendingPermission = req
        case .notification:
            // Foreground notifications arriving over WS — iOS won't show a
            // banner automatically; UI surfaces these in a toast/badge.
            break
        case .ping:
            Task { try? await self.client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    private func applySessionUpdate(_ update: SessionUpdatePayload) {
        switch update.kind {
        case .messageAppended:
            if let m = update.message {
                messagesBySession[update.sessionID, default: []].append(m)
            }
        case .messageUpdated:
            if let m = update.message,
               var list = messagesBySession[update.sessionID],
               let idx = list.firstIndex(where: { $0.id == m.id }) {
                list[idx] = m
                messagesBySession[update.sessionID] = list
            }
        case .streamingStarted, .streamingFinished, .statusChanged:
            // Surface as a flag on the relevant session row.
            break
        }
    }

    private func requestSnapshot() async {
        guard isPaired else { return }
        let payload = RequestSnapshotPayload(activeSessionID: activeSessionID)
        try? await client.send(.requestSnapshot(payload), toHex: pairedDesktopPubkey)
    }

    private func reportAPNsTokenIfPending() async {
        guard isPaired,
              let tokenHex = apnsTokenHex,
              let env = apnsEnvironment else { return }
        let payload = APNsTokenPayload(tokenHex: tokenHex, environment: env)
        try? await client.send(.apnsToken(payload), toHex: pairedDesktopPubkey)
    }

    // MARK: - Persistence

    private func loadPairedDesktop() {
        pairedDesktopPubkey = UserDefaults.standard.string(forKey: "mobileSync.desktopPubkey") ?? ""
        pairedDesktopName = UserDefaults.standard.string(forKey: "mobileSync.desktopName") ?? ""
        isPaired = !pairedDesktopPubkey.isEmpty
    }

    private func savePairedDesktop() {
        UserDefaults.standard.set(pairedDesktopPubkey, forKey: "mobileSync.desktopPubkey")
        UserDefaults.standard.set(pairedDesktopName, forKey: "mobileSync.desktopName")
    }
}

#if canImport(UIKit)
import UIKit
#endif
