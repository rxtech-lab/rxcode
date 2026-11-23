import FixtureWire
import Foundation
import Network

final class FixtureService: NSObject, ProbeService {
    private let queue = DispatchQueue(label: "RxCode.ExtensionRuntime.service")
    private weak var connection: NSXPCConnection?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    static func accept(_ connection: NSXPCConnection) -> Bool {
        let service = FixtureService()
        service.connection = connection
        connection.exportedInterface = NSXPCInterface(with: ProbeService.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeEvents.self)
        connection.invalidationHandler = { service.stopListener {} }
        connection.resume()
        return true
    }

    func handshake(reply: @escaping (Int, String) -> Void) {
        reply(Probe.major, Bundle.main.bundleIdentifier ?? "")
    }

    func start(_ streamID: String) {
        guard let remote = connection?.remoteObjectProxy as? ProbeEvents else { return }
        emit(1, on: streamID, to: remote)
    }

    private func emit(_ number: Int, on id: String, to remote: ProbeEvents) {
        remote.chunk(id, sequence: number) { accepted in
            guard accepted else { return }
            if number == 3 {
                remote.finished(id)
            } else {
                self.emit(number + 1, on: id, to: remote)
            }
        }
    }

    func startListener(reply: @escaping (Int, String?) -> Void) {
        queue.async { [self] in
            guard self.listener == nil else {
                reply(0, "The listener is already running.")
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                let listener = try NWListener(using: parameters)
                var replied = false
                listener.stateUpdateHandler = { [weak listener] state in
                    guard !replied else { return }
                    switch state {
                    case .ready:
                        replied = true
                        reply(Int(listener?.port?.rawValue ?? 0), nil)
                    case .failed(let error):
                        replied = true
                        reply(0, error.localizedDescription)
                    case .cancelled:
                        replied = true
                        reply(0, "Listener stopped.")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] client in self?.serve(client) }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                reply(0, error.localizedDescription)
            }
        }
    }

    private func serve(_ client: NWConnection) {
        let key = ObjectIdentifier(client)
        clients[key] = client
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.clients.removeValue(forKey: key)
            default: break
            }
        }
        client.start(queue: queue)
        readRequest(from: client, buffer: Data())
    }

    private func readRequest(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            guard let data, error == nil, buffer.count + data.count <= 8192 else {
                client.cancel()
                return
            }
            let request = buffer + data
            guard let header = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { client.cancel() } else { self.readRequest(from: client, buffer: request) }
                return
            }
            let line = String(decoding: request[..<header.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first
            // Keep this request open until the host disables or stops the contributor.
            if line == "GET /hold HTTP/1.1" { return }
            let ok = line == "GET /probe HTTP/1.1"
            let body = ok ? Bundle.main.bundleIdentifier ?? "" : ""
            let status = ok ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
        }
    }

    func stopListener(reply: @escaping () -> Void) {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values { client.cancel() }
            self.clients.removeAll()
            reply()
        }
    }
}
