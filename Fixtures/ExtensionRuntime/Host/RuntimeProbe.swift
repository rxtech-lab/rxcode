import ExtensionFoundation
import ExtensionKit
import FixtureWire
import SwiftUI

@main
struct RuntimeProbe: App {
    var body: some Scene {
        Window("Extension Runtime Probe", id: "probe") { ProbeWindow() }
    }
}

private struct ProbeWindow: View {
    @State private var monitor: AppExtensionPoint.Monitor?
    @State private var sessions: [String: ProbeSession] = [:]
    @State private var showBrowser = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let identities = monitor?.identities, !identities.isEmpty {
                    List(identities, id: \.self) { identity in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(identity.bundleIdentifier).font(.headline)
                                if let session = sessions[identity.id] {
                                    Text(session.status)
                                    if let port = session.port { Text(verbatim: "127.0.0.1:\(port)").monospaced() }
                                }
                            }
                            Spacer()
                            if identity.bundleIdentifier == Bundle.main.infoDictionary?["ProbeCombinedID"] as? String {
                                CombinedProbe(identity: identity)
                            } else if let session = sessions[identity.id], session.active {
                                ProbeControls(session: session)
                            } else {
                                Button("Run") { start(identity, paired: false) }
                                if association(for: identity)?.service == identity.bundleIdentifier {
                                    Button("Run with Sidebar") { start(identity, paired: true) }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Enabled Contributors", systemImage: "puzzlepiece.extension",
                                           description: Text(errorMessage ?? "Enable the fixtures in Manage Extensions."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar { Button("Manage Extensions…") { showBrowser = true } }
        }
        .frame(minWidth: 620, minHeight: 420)
        .sheet(isPresented: $showBrowser) {
            NavigationStack {
                SystemExtensionBrowser()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar { Button("Done") { showBrowser = false } }
            }
            .frame(minWidth: 540, minHeight: 480)
        }
        .task {
            do {
                let available = try await AppExtensionPoint.Monitor(appExtensionPoint: .workspaceContributions)
                try await available.addAppExtensionPoint(.workspaceServices)
                monitor = available
                if let index = CommandLine.arguments.firstIndex(of: "--observe-combined"),
                   CommandLine.arguments.indices.contains(index + 1) {
                    await observeCombined(available, containerPath: CommandLine.arguments[index + 1])
                }
            }
            catch {
                errorMessage = error.localizedDescription
                print("Monitor failed: \(error.localizedDescription)")
                fflush(stdout)
                if CommandLine.arguments.contains("--observe-combined") { NSApp.terminate(nil) }
            }
        }
        .onChange(of: monitor?.identities, initial: true) {
            let identities = monitor?.identities ?? []
            print("Enabled: \(identities.map(\.bundleIdentifier).sorted()); unapproved: \(monitor?.state.unapprovedCount ?? 0)")
            fflush(stdout)
            for (id, session) in sessions where !identities.contains(session.identity)
                || session.sceneIdentity.map({ !identities.contains($0) }) == true {
                session.stop("System removed identity")
                sessions.removeValue(forKey: id)
            }
        }
        .onDisappear {
            for session in sessions.values { session.stop("Window closed") }
        }
    }

    /// Measure from the start of container opening. Only enabled identities are individually identifiable.
    @MainActor
    private func observeCombined(_ monitor: AppExtensionPoint.Monitor, containerPath: String) async {
        defer { fflush(stdout); NSApp.terminate(nil) }
        guard let expected = Bundle.main.infoDictionary?["ProbeCombinedID"] as? String else { return }
        let start = ContinuousClock.now
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            _ = try await NSWorkspace.shared.openApplication(at: URL(filePath: containerPath), configuration: configuration)
            while start.duration(to: .now) < .seconds(5),
                  !monitor.identities.contains(where: { $0.bundleIdentifier == expected }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let count = monitor.identities.filter { $0.bundleIdentifier == expected }.count
            print("Observed \(expected): enabled matches=\(count), all unapproved=\(monitor.state.unapprovedCount), all disabled=\(monitor.state.disabledCount), elapsed=\(start.duration(to: .now))")
        } catch { print("Probe observation failed: \(error.localizedDescription)") }
    }

    private func association(for identity: AppExtensionIdentity) -> ProbeAssociation? {
        ProbeAssociation.all.first { $0.service == identity.bundleIdentifier || $0.sidebar == identity.bundleIdentifier }
    }

    private func start(_ identity: AppExtensionIdentity, paired: Bool) {
        guard let association = association(for: identity) else { return }
        let scene: AppExtensionIdentity?
        if paired {
            guard let matches = monitor?.identities.filter({ $0.bundleIdentifier == association.sidebar }),
                  matches.count == 1 else { return }
            scene = matches[0]
        } else {
            scene = identity.bundleIdentifier == association.sidebar ? identity : nil
        }
        let session = ProbeSession(identity, association: association, scene: scene)
        sessions[identity.id] = session
        Task { await session.run() }
    }
}

private struct ProbeControls: View {
    @Bindable var session: ProbeSession

    var body: some View {
        Button("Check Listener") { Task { await session.checkListener() } }
            .disabled(session.port == nil)
        Button("Stop") { session.stop("Stopped by host") }
            .sheet(isPresented: $session.showScene, onDismiss: session.sceneDismissed) {
                HostedFixtureScene(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 480, minHeight: 360)
            }
    }
}

private struct HostedFixtureScene: NSViewControllerRepresentable {
    let session: ProbeSession

    func makeCoordinator() -> Coordinator { Coordinator(session) }

    func makeNSViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.delegate = context.coordinator
        if let scene = session.sceneIdentity {
            controller.configuration = .init(appExtension: scene, sceneID: Probe.scene)
        }
        return controller
    }

    func updateNSViewController(_ controller: EXHostViewController, context: Context) {}

    static func dismantleNSViewController(_ controller: EXHostViewController, coordinator: Coordinator) {
        controller.configuration = nil
        coordinator.connection?.invalidate()
    }

    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        let session: ProbeSession
        var connection: NSXPCConnection?
        init(_ session: ProbeSession) { self.session = session }

        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            guard let scene = session.sceneIdentity else { return }
            do {
                let connection = try viewController.makeXPCConnection()
                self.connection = connection
                connection.setCodeSigningRequirement(session.association.requirement(for: scene.bundleIdentifier))
                connection.remoteObjectInterface = NSXPCInterface(with: ProbeService.self)
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak session] error in
                    Task { @MainActor in session?.stop(error.localizedDescription) }
                } as? ProbeService
                proxy?.handshake { [weak session] major, bundle in
                    Task { @MainActor in
                        guard major == Probe.major, bundle == scene.bundleIdentifier else {
                            session?.stop("Scene handshake failed")
                            return
                        }
                        session?.sceneActivated()
                    }
                }
            } catch { session.stop(error.localizedDescription) }
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) {
            if let error { session.stop(error.localizedDescription) }
        }
    }
}
