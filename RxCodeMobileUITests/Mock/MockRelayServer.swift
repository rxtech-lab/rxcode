import CryptoKit
import Foundation
import Network
import RxCodeCore
import RxCodeSync

/// An in-process WebSocket server that stands in for both the relay router and
/// the paired desktop peer during UI tests.
///
/// It listens on an ephemeral `localhost` port, accepts the app's WebSocket
/// connection, decrypts the envelopes the app sends using `RxCodeSync`'s own
/// crypto, and replies with canned `snapshot` payloads built from `MockFixtures`.
/// The app is paired against this server's deterministic desktop identity by the
/// UI-test launch arguments, so no real QR-code pairing handshake happens.
///
/// The wire framing mirrors `RelayClient` exactly: a plain `JSONEncoder` (default
/// `.deferredToDate`), `SessionCrypto.seal`/`open` with no extra salt, and the
/// sealed `Envelope` sent as a binary WebSocket message.
nonisolated final class MockRelayServer: @unchecked Sendable {

    enum MockError: Error {
        case startTimedOut
        case noPort
    }

    /// Deterministic 32-byte Curve25519 private key. The matching public-key hex
    /// is handed to the app via launch arguments so it pairs against exactly
    /// this identity. Any fixed 32 bytes form a valid X25519 scalar.
    private static let desktopPrivateKeyBytes = [UInt8](repeating: 0x42, count: 32)

    /// The desktop identity the mock impersonates.
    let desktopIdentity: DeviceIdentity
    var desktopPublicKeyHex: String { desktopIdentity.publicKeyHex }

    private let baseFixtures: MockFixtures
    private let queue = DispatchQueue(label: "com.idealapp.RxCodeMobile.MockRelayServer")

    private var listener: NWListener?
    private var connection: NWConnection?
    /// Learned from the first decrypted envelope's `from` field.
    private var mobilePublicKey: Curve25519.KeyAgreement.PublicKey?

    // MARK: - Dynamic state
    //
    // Sessions/threads that the test created at runtime by sending a
    // `newSessionRequest`. The mock server treats those exactly like persisted
    // fixture rows — they ride along in every snapshot from then on so the
    // mobile app sees a stable thread on subsequent refreshes/subscribes,
    // letting tests assert the chat view stays populated after creation.
    private var dynamicSessions: [SessionSummary] = []
    private var dynamicThreadSummaries: [MobileThreadSummary] = []
    private var dynamicMessagesBySession: [String: [ChatMessage]] = [:]
    private var newSessionCounter = 0

    /// Ephemeral port the listener bound to. Valid after `start()` returns.
    private(set) var port: UInt16 = 0

    /// WebSocket URL the app should connect to. Valid only after `start()`.
    var relayURL: String { "ws://127.0.0.1:\(port)/ws" }

    init(fixtures: MockFixtures) {
        self.baseFixtures = fixtures
        // Fixed 32 bytes — guaranteed a valid private key, so `try!` is safe.
        let key = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(Self.desktopPrivateKeyBytes)
        )
        self.desktopIdentity = DeviceIdentity(privateKey: key)
    }

    // MARK: - Lifecycle

    /// Starts the listener and blocks until it is ready (or fails). Safe to call
    /// from the test's `setUp`.
    func start() throws {
        let wsOptions = NWProtocolWebSocket.Options()
        // Auto-answer the app's WebSocket pings — `RelayClient` only flips to
        // `.connected` once a ping round-trips, which is what makes the app send
        // its first `requestSnapshot`.
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let failure = Locked<Error?>(nil)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw MockError.startTimedOut
        }
        if let error = failure.value {
            listener.cancel()
            throw error
        }
        guard let boundPort = listener.port?.rawValue else {
            listener.cancel()
            throw MockError.noPort
        }
        port = boundPort
    }

    /// Tears the server down. Safe to call from the test's `tearDown`.
    func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(data, on: connection)
            }
            // Stop the loop once the peer closes (no data) or errors.
            if error == nil, data != nil {
                self.receive(on: connection)
            }
        }
    }

    /// Decrypt one inbound envelope and reply if it is a payload we mock.
    private func handleIncoming(_ raw: Data, on connection: NWConnection) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: raw),
              let nonce = envelope.nonceData,
              let ciphertext = envelope.ciphertextData,
              let fromRaw = Self.data(fromHex: envelope.from),
              let mobileKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: fromRaw)
        else { return }

        mobilePublicKey = mobileKey

        guard let plaintext = try? SessionCrypto.open(
            ciphertext: ciphertext,
            nonce: nonce,
            recipient: desktopIdentity.privateKey,
            sender: mobileKey
        ),
            let payload = try? decoder.decode(Payload.self, from: plaintext)
        else { return }

        switch payload {
        case .requestSnapshot(let request):
            send(.snapshot(currentSnapshot(activeSessionID: request.activeSessionID)),
                 on: connection)
        case .subscribeSession(let request):
            send(.snapshot(currentSnapshot(activeSessionID: request.sessionID)),
                 on: connection)
        case .loadMoreMessages(let request):
            // The fixture window is the whole thread, so there is nothing older.
            send(.moreMessages(MoreMessagesPayload(
                clientRequestID: request.clientRequestID,
                sessionID: request.sessionID,
                messages: [],
                hasMore: false
            )), on: connection)
        case .newSessionRequest(let request):
            let sessionID = registerNewSession(for: request)
            send(.snapshot(currentSnapshot(activeSessionID: sessionID)), on: connection)
        default:
            // pairRequest, apnsToken, userMessage, ping, … — decrypt and ignore.
            break
        }
    }

    // MARK: - Snapshot assembly

    /// Builds a `snapshot` payload reflecting the current base fixtures plus
    /// any sessions that were created at runtime via `newSessionRequest`.
    private func currentSnapshot(activeSessionID: String?) -> SnapshotPayload {
        let sessions = baseFixtures.sessions + dynamicSessions
        let threadSummaries = baseFixtures.threadSummaries + dynamicThreadSummaries
        let messages = activeSessionID.flatMap { id in
            dynamicMessagesBySession[id] ?? baseFixtures.messagesBySession[id]
        }
        return SnapshotPayload(
            projects: baseFixtures.projects,
            sessions: sessions,
            branchBriefings: baseFixtures.branchBriefings,
            threadSummaries: threadSummaries,
            settings: nil,
            activeSessionID: activeSessionID,
            activeSessionMessages: messages,
            activeSessionHasMore: false,
            projectBranches: nil,
            usage: nil,
            hostMetrics: nil,
            runProfiles: nil,
            runTasks: nil,
            webProxy: nil
        )
    }

    /// Materializes a fresh session + thread summary + canned transcript for a
    /// `newSessionRequest`, mirroring what the desktop would persist before
    /// pushing a snapshot back. Returns the new session ID so the snapshot
    /// reply can mark it as active.
    private func registerNewSession(for request: NewSessionRequestPayload) -> String {
        newSessionCounter += 1
        let sessionID = "sess-new-\(newSessionCounter)"
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let title = request.initialText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
            .description ?? "New Thread"
        // The briefing detail's branch is plumbed through `preferredBranch`, but
        // the mock doesn't actually receive it on the wire — fall back to the
        // first briefing's branch for that project so the new thread lands in
        // the same briefing group the test is asserting against.
        let branch = baseFixtures.branchBriefings
            .first(where: { $0.projectId == request.projectID })?.branch ?? "main"

        let session = SessionSummary(
            id: sessionID,
            projectId: request.projectID,
            title: title,
            updatedAt: now,
            isPinned: false,
            isArchived: false
        )
        let summary = MobileThreadSummary(
            sessionId: sessionID,
            projectId: request.projectID,
            branch: branch,
            title: title,
            summary: "",
            updatedAt: now
        )
        var transcript: [ChatMessage] = []
        if let text = request.initialText, !text.isEmpty {
            transcript.append(ChatMessage(role: .user, content: text, timestamp: now))
        }
        transcript.append(ChatMessage(
            role: .assistant,
            content: "Assistant reply inside \(title).",
            isResponseComplete: true,
            timestamp: now
        ))

        dynamicSessions.append(session)
        dynamicThreadSummaries.append(summary)
        dynamicMessagesBySession[sessionID] = transcript
        return sessionID
    }

    /// Seal `payload` for the mobile peer and send it as a binary WS message.
    private func send(_ payload: Payload, on connection: NWConnection) {
        guard let mobileKey = mobilePublicKey,
              let plaintext = try? JSONEncoder().encode(payload),
              let sealed = try? SessionCrypto.seal(
                  plaintext: plaintext,
                  sender: desktopIdentity.privateKey,
                  recipient: mobileKey
              )
        else { return }

        let envelope = Envelope(
            to: Self.hexString(mobileKey.rawRepresentation),
            from: desktopPublicKeyHex,
            nonce: sealed.nonce,
            ct: sealed.ciphertext
        )
        guard let raw = try? JSONEncoder().encode(envelope) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        connection.send(content: raw, contentContext: context,
                        completion: .contentProcessed { _ in })
    }

    // MARK: - Hex helpers

    /// `RxCodeSync`'s own hex helpers are `internal`, so the mock keeps its own
    /// lowercase encoder/decoder that produces an identical representation.
    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHex hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index..<index + 2]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        return Data(bytes)
    }
}

/// Minimal mutex so the listener's state handler can hand a start-up error back
/// to the waiting `start()` call without a data-race warning.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
