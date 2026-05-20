import Foundation
import CryptoKit

/// Manages a single WebSocket to the relay. Handles E2E encrypt/decrypt, ping
/// keepalive, and exponential-backoff reconnect.
///
/// The relay sees only `Envelope` and `DeliveryFailedNotice` — every other
/// payload is encrypted before send and decrypted after receive.
public actor RelayClient {
    public struct Inbound: Sendable {
        public let from: Curve25519.KeyAgreement.PublicKey
        public let fromHex: String
        public let payload: Payload
    }

    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(nextAttemptInSeconds: Int)
    }

    public enum Event: Sendable {
        case stateChanged(ConnectionState)
        case inbound(Inbound)
        case deliveryFailed(toHex: String)
    }

    /// WebSocket frame ceiling. The 1 MiB `URLSessionWebSocketTask` default is
    /// too small for snapshots that bundle a full thread history; 32 MiB covers
    /// realistic threads with room to spare.
    private static let maxWebSocketMessageSize = 32 * 1024 * 1024

    private let identity: DeviceIdentity
    private let relayURL: URL
    private let session: URLSession

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
        guard task == nil else { return }
        shouldReconnect = true
        openSocket()
    }

    public func disconnect() {
        shouldReconnect = false
        closeSocketLocally()
        emit(.stateChanged(.disconnected))
        state = .disconnected
    }

    /// Encrypt `payload` for `recipient` and send the resulting envelope.
    public func send(_ payload: Payload, to recipient: Curve25519.KeyAgreement.PublicKey) async throws {
        guard let task else { throw RelayError.notConnected }
        let plaintext = try JSONEncoder().encode(payload)
        let (nonce, ct) = try SessionCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: recipient
        )
        let envelope = Envelope(
            to: recipient.rawRepresentation.hexString,
            from: identity.publicKeyHex,
            nonce: nonce,
            ct: ct
        )
        let raw = try JSONEncoder().encode(envelope)
        try await task.send(.data(raw))
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
        updateState(.connecting)

        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            handleSocketFailure(error: RelayError.invalidURL)
            return
        }
        components.path = Self.webSocketPath(from: components.path)
        components.queryItems = [URLQueryItem(name: "pubkey", value: identity.publicKeyHex)]
        guard let url = components.url else {
            handleSocketFailure(error: RelayError.invalidURL)
            return
        }

        let newTask = session.webSocketTask(with: url)
        // The default frame limit is 1 MiB. A snapshot carries a full thread
        // history (tool results with file contents, diffs, command output),
        // which routinely exceeds that — `task.send` would then throw and the
        // snapshot would silently never reach the peer. Raise the ceiling so
        // history sync isn't dropped. Applies to both send and receive.
        newTask.maximumMessageSize = Self.maxWebSocketMessageSize
        task = newTask
        newTask.resume()

        // URLSessionWebSocketTask reports success only via receive/ping. Stay
        // in .connecting and let the first successful ping flip us to
        // .connected, so the UI reflects the real handshake outcome.
        startReceiveLoop()
        sendPing()
        startPingLoop()
    }

    private static func webSocketPath(from basePath: String) -> String {
        let trimmed = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "/ws" }
        guard trimmed.split(separator: "/").last != "ws" else { return "/" + trimmed }
        return "/" + trimmed + "/ws"
    }

    private func markConnected() {
        if state != .connected {
            reconnectAttempt = 0
            updateState(.connected)
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                guard let self else { return }
                await self.sendPing()
            }
        }
    }

    private func sendPing() {
        task?.sendPing { [weak self] error in
            if let error {
                Task { await self?.handleSocketFailure(error: error) }
            } else {
                Task { await self?.markConnected() }
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
            handleSocketFailure(error: error)
        }
    }

    private func handleIncoming(_ raw: Data) {
        let decoder = JSONDecoder()
        if let notice = try? decoder.decode(DeliveryFailedNotice.self, from: raw),
           notice.type == "delivery_failed" {
            emit(.deliveryFailed(toHex: notice.to))
            return
        }
        guard let env = try? decoder.decode(Envelope.self, from: raw) else { return }
        guard let nonce = env.nonceData,
              let ct = env.ciphertextData,
              let fromRaw = Data(hexString: env.from),
              let fromKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: fromRaw)
        else { return }
        do {
            let plaintext = try SessionCrypto.open(
                ciphertext: ct,
                nonce: nonce,
                recipient: identity.privateKey,
                sender: fromKey
            )
            let payload = try decoder.decode(Payload.self, from: plaintext)
            emit(.inbound(Inbound(from: fromKey, fromHex: env.from, payload: payload)))
        } catch {
            // Decrypt or decode failure means the sender isn't a paired peer
            // we know how to talk to, OR the wire format drifted. Drop quietly.
            return
        }
    }

    private func handleSocketFailure(error: Error) {
        closeSocketLocally()
        guard shouldReconnect else { return }
        reconnectAttempt += 1
        let delay = min(30, Int(pow(2.0, Double(reconnectAttempt))))
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
