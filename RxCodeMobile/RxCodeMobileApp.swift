import SwiftUI
import RxCodeCore
import RxCodeSync
import TipKit

@main
struct RxCodeMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = MobileAppState()
    @State private var windowState = WindowState()
    @State private var liveActivityCoordinator = MobileLiveActivityCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        // Suppress TipKit popovers during UI tests — they overlay the UI and
        // intercept taps. No-op outside a UI-test launch.
        if UITestSupport.isActive {
            Tips.hideAllTipsForTesting()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environment(windowState)
                .onAppear {
                    appDelegate.mobileState = state
                    liveActivityCoordinator.bind(state: state)
                    state.start()
                }
                .onOpenURL { url in
                    handlePairingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handlePairingURL(url)
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            NSLog("[Lifecycle] scenePhase \(String(describing: oldPhase)) -> \(String(describing: newPhase))")
            state.handleScenePhase(newPhase)
        }
    }

    private func handlePairingURL(_ url: URL) {
        guard Self.isPairingURL(url) else { return }
        MobileHaptics.buttonTap()
        Task {
            await state.pair(from: url, displayName: UIDevice.current.name)
        }
    }

    private static func isPairingURL(_ url: URL) -> Bool {
        if url.absoluteString.hasPrefix(PairingToken.legacySchemePrefix) {
            return true
        }
        guard url.scheme == "https",
              url.host?.lowercased() == PairingToken.deeplinkHost,
              url.path == PairingToken.deeplinkPath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true else {
            return false
        }
        return true
    }
}
