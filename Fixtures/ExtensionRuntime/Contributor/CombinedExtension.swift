import ExtensionFoundation
import ExtensionKit
import SwiftUI
import XPC

private struct ProbeGeometry: View {
    let message: String
    var body: some View {
        GeometryReader { geometry in
            VStack {
                Text(verbatim: message)
                Text("\(Int(geometry.size.width)) × \(Int(geometry.size.height)) pt")
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(.blue)
        }
    }
}

#if canImport(RxCodeExtensionSDK)
import RxCodeExtensionSDK

@MainActor @Observable
private final class ProbeSceneState {
    var status = "Awaiting host context"
}

private struct ProbeScenes: AppExtensionScene {
    @AppExtensionSceneBuilder var body: some AppExtensionScene {
        callbackScene(id: "inspector")
        callbackScene(id: "usage-detail")
    }

    private func callbackScene(id: String) -> PrimitiveAppExtensionScene {
        let state = ProbeSceneState()
        return PrimitiveAppExtensionScene(id: id) {
            ProbeGeometry(message: state.status)
        } onConnection: { connection in
            ExtensionSceneConnection.accept(connection) { context, host in
                Task { @MainActor in
                    do {
                        let echo: String = try await host.call(.storageSet, ["key": id + "-generation", "value": context.generation],
                                                              returning: String.self)
                        state.status = echo == context.generation ? "Scene callback verified" : "Scene callback mismatch"
                    } catch { state.status = "Scene callback failed" }
                }
            }
        }
    }
}

@main
struct CombinedExtension: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            ProbeScenes(),
            configuration: ExtensionService.configuration(scenes: ["inspector", "usage-detail"],
                                                         test: { "Probe received " + $0 }) { integration, host in
                let nonce = UUID().uuidString
                let echo: String = try await host.call(.storageSet, ["key": "service-nonce", "value": nonce], returning: String.self)
                guard echo == nonce else { throw ExtensionCallError.invalidRequest }
                return ExtensionUsageSnapshot(integration: integration, scope: "Fixture", period: "Last callback", metrics: [
                    .init(id: "callback", title: "Verified XPC callback", value: 1, unit: "callback")
                ])
            }
        )
    }
}
#else
import FixtureWire

/// Exercise the same XPCSession transport as RxCode's service runtime.
private struct CallbackProbe: XPCPeerHandler {
    let session: XPCSession

    func handleIncomingRequest(_ message: [String: String]) -> (any Encodable)? {
        guard let nonce = message["hello"] else { return nil }
        do {
            try session.send(["callback": nonce]) { (reply: Result<[String: String], Error>) in
                guard let value = try? reply.get(), value["ack"] == nonce else { return }
                try? session.send(["completed": nonce])
            }
            return ["accepted": nonce]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}

@main
struct CombinedExtension: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: Probe.scene) {
                ProbeGeometry(message: "RxCode combined fixture")
            } onConnection: { FixtureService.accept($0) },
            configuration: ConnectionHandler { (request: XPCListener.IncomingSessionRequest) in
                request.accept { session in CallbackProbe(session: session) }
            }
        )
    }
}
#endif
