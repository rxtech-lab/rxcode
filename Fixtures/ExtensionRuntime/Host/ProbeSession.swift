import ExtensionFoundation
import FixtureWire
import Foundation
import Observation

private final class StreamReceiver: NSObject, ProbeEvents {
    weak var owner: ProbeSession?

    func chunk(_ streamID: String, sequence: Int, acknowledge: @escaping (Bool) -> Void) {
        Task { @MainActor in
            guard let owner else { acknowledge(false); return }
            owner.receive(streamID, sequence: sequence, acknowledge: acknowledge)
        }
    }

    func finished(_ streamID: String) {
        Task { @MainActor in owner?.finish(streamID) }
    }
}

/// Owns the process and its only service connection for the duration of the probe.
@MainActor @Observable
final class ProbeSession: Identifiable {
    let id = UUID()
    let association: ProbeAssociation
    let sceneIdentity: AppExtensionIdentity?
    let identity: AppExtensionIdentity
    let streamID = UUID().uuidString
    var showScene = false
    private(set) var status = "Activating"
    private(set) var port: Int?
    private(set) var active = true
    private var process: AppExtensionProcess?
    private var connection: NSXPCConnection?
    private var remote: ProbeService?
    private var lastSequence = 0
    private var terminalCount = 0
    private var acknowledge: ((Bool) -> Void)?
    private var timeout: Task<Void, Never>?

    init(_ identity: AppExtensionIdentity, association: ProbeAssociation, scene: AppExtensionIdentity?) {
        self.identity = identity
        self.association = association
        self.sceneIdentity = scene
    }

    func run() async {
        armTimeout()
        do {
            let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity) { [weak self] in
                Task { @MainActor in self?.stop("Process interrupted") }
            })
            guard active else { process.invalidate(); return }
            self.process = process
            let connection = try process.makeXPCConnection()
            connection.setCodeSigningRequirement(association.requirement(for: identity.bundleIdentifier))
            self.connection = connection
            let receiver = StreamReceiver()
            receiver.owner = self
            connection.exportedInterface = NSXPCInterface(with: ProbeEvents.self)
            connection.exportedObject = receiver
            connection.remoteObjectInterface = NSXPCInterface(with: ProbeService.self)
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.stop("Connection interrupted") }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.stop("Connection invalidated") }
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor in self?.stop(error.localizedDescription) }
            }) as? ProbeService else {
                stop("Missing service proxy")
                return
            }
            remote = proxy
            proxy.handshake { [weak self] major, bundle in
                Task { @MainActor in self?.begin(major: major, bundle: bundle) }
            }
        } catch { stop(error.localizedDescription) }
    }

    private func begin(major: Int, bundle: String) {
        guard active else { return }
        guard major == Probe.major, bundle == identity.bundleIdentifier else {
            stop("Unexpected handshake from \(bundle), major \(major)")
            return
        }
        record("Handshake v\(major)")
        // The numbered turn and listener are independent probes on the same service.
        remote?.start(streamID)
        remote?.startListener { [weak self] port, failure in
            Task { @MainActor in
                guard let self, self.active else { return }
                guard failure == nil, (1...65535).contains(port) else {
                    self.stop(failure ?? "Invalid listener port")
                    return
                }
                self.port = port
                await self.checkListener()
            }
        }
    }

    func checkListener() async {
        guard active, let port,
              let url = URL(string: "http://127.0.0.1:\(port)/probe") else { return }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard active else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(decoding: data, as: UTF8.self) == identity.bundleIdentifier else {
                stop("Unexpected loopback response")
                return
            }
            log("Loopback response verified on \(port)")
        } catch {
            if active { stop(error.localizedDescription) }
        }
    }

    fileprivate func receive(_ id: String, sequence: Int, acknowledge: @escaping (Bool) -> Void) {
        guard active, id == streamID, sequence == lastSequence + 1,
              (1...3).contains(sequence), terminalCount == 0 else {
            acknowledge(false)
            if active { stop("Unexpected chunk \(sequence) for \(id)") }
            return
        }
        lastSequence = sequence
        record("Received chunk \(sequence)")
        if sceneIdentity != nil, sequence < 3 {
            self.acknowledge = acknowledge
            showScene = sequence == 1
        } else {
            acknowledge(true)
        }
    }

    func sceneActivated() {
        guard active, showScene, lastSequence == 1 else { return }
        log("Scene activated after chunk 1")
        releaseChunk()
    }

    func sceneDismissed() {
        guard active else { return }
        guard !showScene, lastSequence == 2 else {
            stop("Scene dismissed before chunk 2")
            return
        }
        log("Last scene dismissed after chunk 2")
        releaseChunk()
    }

    private func releaseChunk() {
        let reply = acknowledge
        acknowledge = nil
        reply?(true)
    }

    fileprivate func finish(_ id: String) {
        guard active else { return }
        terminalCount += 1
        guard id == streamID, lastSequence == 3, terminalCount == 1 else {
            stop("Unexpected terminal event for \(id)")
            return
        }
        timeout?.cancel()
        record("Stream completed once")
    }

    func stop(_ reason: String) {
        guard active else { return }
        active = false
        timeout?.cancel()
        showScene = false
        acknowledge?(false)
        acknowledge = nil
        connection?.invalidate()
        process?.invalidate()
        remote = nil
        connection = nil
        process = nil
        port = nil
        record(reason)
    }

    private func armTimeout() {
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.stop("Timed out waiting for stream completion")
        }
    }

    private func record(_ message: String) {
        status = message
        log(message)
    }

    private func log(_ message: String) {
        print("\(identity.bundleIdentifier) \(streamID) \(message)")
        fflush(stdout)
    }
}
