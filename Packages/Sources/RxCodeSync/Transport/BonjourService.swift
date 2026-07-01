import Foundation
import Network
import os

/// The Bonjour service type both devices advertise/browse for LAN discovery.
public let rxcodeSyncBonjourType = "_rxcode-sync._tcp"

/// A peer discovered on the LAN, matched to a paired pubkey via its TXT record.
public struct DiscoveredDirectPeer: Sendable {
    public let pubkeyHex: String
    public let endpoint: NWEndpoint
}

/// Advertises a `_rxcode-sync._tcp` listener carrying our pubkey in TXT, and
/// streams inbound connections a dialing peer opens against it. On the desktop
/// this is how a mobile's direct link is accepted; the coordinator adopts each
/// connection into a `DirectTransport` and routes it once the peer is known.
public actor BonjourAdvertiser {
    private let localPubkeyHex: String
    private let queue = DispatchQueue(label: "com.idealapp.RxCodeSync.bonjour.listen")
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "Bonjour")

    private var listener: NWListener?
    private var continuations: [UUID: AsyncStream<NWConnection>.Continuation] = [:]
    private var portReadyContinuations: [UUID: AsyncStream<UInt16>.Continuation] = [:]
    private var boundPort: UInt16?

    public init(localPubkeyHex: String) {
        self.localPubkeyHex = localPubkeyHex
    }

    /// A stream of inbound connections accepted by the listener.
    public func acceptedConnections() -> AsyncStream<NWConnection> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Emits the OS-assigned TCP port once the listener reaches `.ready`. Lets the
    /// hub kick off WAN port mapping and candidate offers only after the port is
    /// actually bound (it's `nil` until then).
    public func portReady() -> AsyncStream<UInt16> {
        AsyncStream { continuation in
            let id = UUID()
            self.portReadyContinuations[id] = continuation
            // If already bound, replay immediately.
            if let boundPort { continuation.yield(boundPort) }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removePortReadyContinuation(id) }
            }
        }
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            var txt = NWTXTRecord()
            txt["pk"] = localPubkeyHex
            txt["v"] = "1"
            listener.service = NWListener.Service(type: rxcodeSyncBonjourType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                // Do NOT start the connection here — the adopting `DirectTransport`
                // owns its lifecycle and calls `start` in `connect()`. Starting it
                // twice is a double-start on the same NWConnection.
                Task { await self?.yield(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.handleListenerReady() }
                case .failed(let error):
                    Task { await self?.logFailure(error) }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            logger.info("[Bonjour] advertising \(rxcodeSyncBonjourType, privacy: .public) pk=\(String(self.localPubkeyHex.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[Bonjour] advertiser start failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The OS-assigned TCP port the listener is bound to, once ready. Used to
    /// build raw-interface and WAN ICE candidates that point at this listener.
    public func listeningPort() -> UInt16? {
        listener?.port?.rawValue
    }

    private func yield(_ connection: NWConnection) {
        for c in continuations.values { c.yield(connection) }
    }

    private func handleListenerReady() {
        guard let port = listener?.port?.rawValue else { return }
        boundPort = port
        logger.info("[Bonjour] listener ready port=\(port, privacy: .public)")
        for c in portReadyContinuations.values { c.yield(port) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
    private func removePortReadyContinuation(_ id: UUID) { portReadyContinuations.removeValue(forKey: id) }
    private func logFailure(_ error: NWError) {
        logger.error("[Bonjour] listener failed error=\(error.localizedDescription, privacy: .public)")
    }
}

/// Browses for `_rxcode-sync._tcp` peers and streams those whose TXT `pk`
/// matches a paired device. The endpoint it yields is dialed directly by a
/// `DirectTransport`.
public actor BonjourBrowser {
    private let queue = DispatchQueue(label: "com.idealapp.RxCodeSync.bonjour.browse")
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "Bonjour")

    private var browser: NWBrowser?
    private var continuations: [UUID: AsyncStream<DiscoveredDirectPeer>.Continuation] = [:]

    public init() {}

    public func discoveries() -> AsyncStream<DiscoveredDirectPeer> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: rxcodeSyncBonjourType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleResults(results) }
        }
        self.browser = browser
        browser.start(queue: queue)
        logger.info("[Bonjour] browsing \(rxcodeSyncBonjourType, privacy: .public)")
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let pk = txt["pk"], !pk.isEmpty else { continue }
            emit(DiscoveredDirectPeer(pubkeyHex: pk, endpoint: result.endpoint))
        }
    }

    private func emit(_ peer: DiscoveredDirectPeer) {
        for c in continuations.values { c.yield(peer) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
}
