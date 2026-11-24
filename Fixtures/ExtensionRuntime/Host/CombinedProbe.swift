import ExtensionFoundation
import ExtensionKit
import FixtureWire
import LightweightCodeRequirements
import SwiftUI
import XPC

/// The fixture build embeds the current machine architecture's CDHash into the isolated host.
struct CombinedProbe: View {
    let identity: AppExtensionIdentity
    @State private var status = "Ready"
    @State private var inspector = false
    @State private var popover = false
    @State private var run = 0
    @State private var process: AppExtensionProcess?
    @State private var session: XPCSession?

    private let cdhash = Bundle.main.infoDictionary?["ProbeCombinedCDHash"] as? String ?? ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(status)
            HStack {
                Button("Test XPC callback") { run += 1 }
                Button("Inspector") { inspector.toggle() }
                Button("Popover") { popover.toggle() }
                    .popover(isPresented: $popover) {
                        CombinedScene(identity: identity, cdhash: cdhash)
                            .frame(width: 360, height: 220)
                    }
            }
        }
        .inspector(isPresented: $inspector) {
            CombinedScene(identity: identity, cdhash: cdhash)
                .inspectorColumnWidth(min: 240, ideal: 320, max: 600)
        }
        .task(id: run) {
            guard run > 0 else { return }
            await checkCallback()
        }
    }

    @MainActor
    private func checkCallback() async {
        let nonce = UUID().uuidString
        let bytes = stride(from: 0, to: cdhash.utf8.count, by: 2).compactMap { offset -> UInt8? in
            UInt8(cdhash.dropFirst(offset).prefix(2), radix: 16)
        }
        guard cdhash.count == 40, bytes.count == 20 else { status = "Missing CDHash"; return }
        let (events, result) = AsyncStream<String>.makeStream()
        let deadline = Task {
            try await Task.sleep(for: .seconds(12))
            result.yield("Timed out")
            result.finish()
        }
        let activation = Task { @MainActor in
            do {
                let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity) {
                    result.yield("Process interrupted")
                    result.finish()
                })
                guard !Task.isCancelled else { process.invalidate(); return }
                self.process = process
                let session = try process.makeXPCSession()
                session.setPeerRequirement(try .codeRequirement(.allOf { CodeDirectoryHash(Data(bytes)) }))
                session.setIncomingMessageHandler { (message: [String: String]) -> (any Encodable)? in
                    if message["callback"] == nonce { return ["ack": nonce] }
                    if message["completed"] == nonce { result.yield("Bidirectional XPC verified"); result.finish() }
                    return nil
                }
                session.setCancellationHandler { error in result.yield(error.localizedDescription); result.finish() }
                try session.activate()
                self.session = session
                try session.send(["hello": nonce]) { (reply: Result<[String: String], Error>) in
                    if (try? reply.get())?["accepted"] != nonce {
                        result.yield("Invalid hello reply")
                        result.finish()
                    }
                }
            } catch { result.yield(error.localizedDescription); result.finish() }
        }
        defer {
            activation.cancel()
            deadline.cancel()
            session?.cancel(reason: "Probe completed")
            process?.invalidate()
            session = nil
            process = nil
        }
        status = "Waiting for callback"
        for await event in events {
            status = event
            print("\(identity.bundleIdentifier) \(event)")
            break
        }
    }
}

private struct CombinedScene: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let cdhash: String

    func makeCoordinator() -> Coordinator { Coordinator(cdhash: cdhash, id: identity.bundleIdentifier) }

    func makeNSViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.delegate = context.coordinator
        controller.configuration = .init(appExtension: identity, sceneID: Probe.scene)
        return controller
    }

    func updateNSViewController(_ controller: EXHostViewController, context: Context) {}

    static func dismantleNSViewController(_ controller: EXHostViewController, coordinator: Coordinator) {
        controller.configuration = nil
        coordinator.connection?.invalidate()
    }

    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        let cdhash: String
        let id: String
        var connection: NSXPCConnection?

        init(cdhash: String, id: String) {
            self.cdhash = cdhash
            self.id = id
        }

        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            do {
                let connection = try viewController.makeXPCConnection()
                connection.setCodeSigningRequirement("cdhash H\"\(cdhash)\"")
                connection.remoteObjectInterface = NSXPCInterface(with: ProbeService.self)
                connection.resume()
                self.connection = connection
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    print("Scene handshake failed: \(error.localizedDescription)")
                } as? ProbeService
                proxy?.handshake { [id] major, identifier in
                    print("Scene handshake \(identifier == id && major == Probe.major ? "passed" : "failed")")
                }
            } catch { print("Scene activation failed: \(error.localizedDescription)") }
        }
    }
}
