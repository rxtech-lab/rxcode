import SwiftUI
import RxCodeCore
import TipKit

@main
struct RxCodeMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = MobileAppState()
    @State private var windowState = WindowState()
    @State private var liveActivityCoordinator = MobileLiveActivityCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseBootstrap.configure()
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
        .onChange(of: scenePhase) { _, newPhase in
            state.handleScenePhase(newPhase)
        }
    }

    private func handlePairingURL(_ url: URL) {
        MobileHaptics.buttonTap()
        Task {
            await state.pair(from: url, displayName: UIDevice.current.name)
        }
    }
}
