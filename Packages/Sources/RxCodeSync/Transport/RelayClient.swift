import Foundation
import CryptoKit
import os

/// Manages a single WebSocket to the relay. Handles E2E encrypt/decrypt, ping
/// keepalive, and exponential-backoff reconnect.
///
/// The relay sees only `Envelope` and `DeliveryFailedNotice` — every other
/// payload is encrypted before send and decrypted after receive.
public actor RelayClient: Transport {
    // The transport event/state types are shared across every `Transport`; keep
    // the historical `RelayClient.Inbound` / `.ConnectionState` / `.Event`
    // spellings as typealiases so existing call sites compile unchanged.
    public typealias Inbound = TransportInbound
    public typealias ConnectionState = TransportConnectionState
    public typealias Event = TransportEvent

    /// WebSocket frame ceiling. The 1 MiB `URLSessionWebSocketTask` default is
    /// too small for sync payloads; 10 MiB is a comfortable safety margin now
    /// that thread history is paged rather than sent in a single frame.
    private static let maxWebSocketMessageSize = 10 * 1024 * 1024

    private let identity: DeviceIdentity
    private let relayURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "RelayClient")

    private var task: URLSessionWebSocketTask?
    private(set) public var state: ConnectionState = .disconnected
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var reconnectAttempt = 0
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var shouldReconnect = true

    public init(identity: DeviceIdentity, relayURL: URL) {
        self.identity = identity
        self.relayURL = relayURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    /// Subscribe to a multiplexed event stream. Each subscriber gets its own
    /// buffered stream; tearing down the AsyncStream's iterator removes the
    /// subscriber.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func connect() {
        guard task == nil else {
            logger.info("[Relay] connect skipped — socket already assigned relay=\(self.relayURL.absoluteString, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            return
        }
        shouldReconnect = true
        logger.info("[Relay] connect requested relay=\(self.relayURL.absoluteString, privacy: .public) localKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        openSocket()
    }

    /// Force a clean reconnect. Unlike `connect()`, this does not bail when a
    /// socket is still assigned — it tears down any existing (possibly stale)
    /// socket first, then reopens. This is the correct entry point on app
    /// foreground: iOS suspends the process in the background, so the socket can
    /// die without `receiveOne`/`sendPing` ever firing the failure callback that
    /// would clear `task`. On resume `task` may still reference a dead socket,
    /// which would make a plain `connect()` no-op forever.
    public func reconnect() {
        shouldReconnect = true
        logger.info("[Relay] reconnect requested relay=\(self.relayURL.absoluteString, privacy: .public) localKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        closeSocketLocally()
        reconnectAttempt = 0
        openSocket()
    }

    public func disconnect() {
        shouldReconnect = false
        logger.info("[Relay] disconnect requested relay=\(self.relayURL.absoluteString, privacy: .public) localKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        closeSocketLocally()
        emit(.stateChanged(.disconnected))
        state = .disconnected
    }

    /// Encrypt `payload` for `recipient` and send the resulting envelope.
    public func send(_ payload: Payload, to recipient: Curve25519.KeyAgreement.PublicKey) async throws {
        guard let task else {
            logger.error("[Relay] send failed not connected type=\(payload.logName, privacy: .public) to=\(String(recipient.rawRepresentation.hexString.prefix(12)), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
            throw RelayError.notConnected
        }
        let raw = try EnvelopeCodec.encode(payload, from: identity, to: recipient)
        do {
            try await task.send(.data(raw))
        } catch {
            logger.error("[Relay] send failed type=\(payload.logName, privacy: .public) to=\(String(recipient.rawRepresentation.hexString.prefix(12)), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: Event) {
        for c in continuations.values { c.yield(event) }
    }

    private func updateState(_ newState: ConnectionState) {
        state = newState
        emit(.stateChanged(newState))
    }

    private func openSocket() {
        // A live socket already exists, or a competing reconnect already won
        // the race. Opening another would register a second connection for the
        // same pubkey on the relay — the cause of duplicate registrations when
        // resuming from background. Never stack sockets.
        guard task == nil else {
            logger.info("[Relay] openSocket skipped — socket already assigned relay=\(self.relayURL.absoluteString, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            return
        }
        // A disconnect() may have landed while a scheduled reconnect was still
        // sleeping; honour it instead of reopening.
        guard shouldReconnect else {
            logger.info("[Relay] openSocket skipped — shouldReconnect=false relay=\(self.relayURL.absoluteString, privacy: .public)")
            return
        }

        updateState(.connecting)

        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            handleSocketFailure(of: nil, error: RelayError.invalidURL)
            return
        }
        components.path = Self.webSocketPath(from: components.path)
        components.queryItems = [URLQueryItem(name: "pubkey", value: identity.publicKeyHex)]
        guard let url = components.url else {
            handleSocketFailure(of: nil, error: RelayError.invalidURL)
            return
        }

        logger.info("[Relay] opening websocket url=\(url.absoluteString, privacy: .public)")
        let newTask = session.webSocketTask(with: url)
        // Raise the 1 MiB default frame limit so large sync payloads aren't
        // silently dropped by `task.send`. Applies to both send and receive.
        newTask.maximumMessageSize = Self.maxWebSocketMessageSize
        task = newTask
        newTask.resume()

        // URLSessionWebSocketTask reports success only via receive/ping. Stay
        // in .connecting and let the first successful ping flip us to
        // .connected, so the UI reflects the real handshake outcome.
        startReceiveLoop()
        sendPing(on: newTask)
        startPingLoop()
    }

    private static func webSocketPath(from basePath: String) -> String {
        let trimmed = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "/ws" }
        guard trimmed.split(separator: "/").last != "ws" else { return "/" + trimmed }
        return "/" + trimmed + "/ws"
    }

    private func markConnected(_ socket: URLSessionWebSocketTask) {
        // A ping that completes after its socket was already replaced must not
        // resurrect a stale connection's state.
        guard socket === task else { return }
        if state != .connected {
            reconnectAttempt = 0
            logger.info("[Relay] connected relay=\(self.relayURL.absoluteString, privacy: .public)")
            updateState(.connected)
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                guard let self else { return }
                await self.pingCurrentSocket()
            }
        }
    }

    private func pingCurrentSocket() {
        guard let task else { return }
        sendPing(on: task)
    }

    private func sendPing(on socket: URLSessionWebSocketTask) {
        socket.sendPing { [weak self] error in
            if let error {
                Task { await self?.handleSocketFailure(of: socket, error: error) }
            } else {
                Task { await self?.markConnected(socket) }
            }
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.receiveOne()
            }
        }
    }

    private func receiveOne() async {
        guard let task else { return }
        do {
            let message = try await task.receive()
            switch message {
            case .data(let data): handleIncoming(data)
            case .string(let s): handleIncoming(Data(s.utf8))
            @unknown default: break
            }
        } catch {
            handleSocketFailure(of: task, error: error)
        }
    }

    private func handleIncoming(_ raw: Data) {
        switch EnvelopeCodec.decode(raw, localIdentity: identity) {
        case .deliveryFailed(let toHex):
            logger.warning("[Relay] delivery failed to=\(String(toHex.prefix(12)), privacy: .public)")
            emit(.deliveryFailed(toHex: toHex))
        case .inbound(let inbound):
            emit(.inbound(inbound))
        case .drop:
            break
        }
    }

    private func handleSocketFailure(of failedTask: URLSessionWebSocketTask?, error: Error) {
        // The receive loop and the ping handler both observe the same dead
        // socket. Only the first report — the one still matching the current
        // task — may drive a reconnect; later reports (including stale pings
        // that resolve after a new socket is already up) are ignored. Without
        // this guard each report would schedule its own reconnect and the
        // client would open, and register, multiple sockets on the relay.
        if let failedTask, failedTask !== task { return }

        closeSocketLocally()
        guard shouldReconnect else { return }
        reconnectAttempt += 1
        // Exponential backoff capped at 30s. Clamp the attempt counter once it
        // reaches the ceiling: left unbounded, pow(2, n) eventually exceeds
        // Int.max (then +inf) and the Int() conversion traps *before* min(30,…)
        // can clamp it. 2^5 = 32 > 30, so the exponent never needs to exceed 5.
        let maxBackoffExponent = 5
        if reconnectAttempt > maxBackoffExponent { reconnectAttempt = maxBackoffExponent }
        let delay = min(30, Int(pow(2.0, Double(reconnectAttempt))))
        logger.error("[Relay] socket failed relay=\(self.relayURL.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public) reconnectIn=\(delay, privacy: .public)s")
        updateState(.reconnecting(nextAttemptInSeconds: delay))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            await self?.openSocket()
        }
    }

    private func closeSocketLocally() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

public enum RelayError: Error, Sendable {
    case notConnected
    case invalidURL
}
