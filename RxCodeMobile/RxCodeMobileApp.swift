import SwiftUI
import RxCodeCore

@main
struct RxCodeMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = MobileAppState()
    @State private var windowState = WindowState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environment(windowState)
                .onAppear {
                    appDelegate.mobileState = state
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
    }

    private func handlePairingURL(_ url: URL) {
        MobileHaptics.buttonTap()
        Task {
            await state.pair(from: url, displayName: UIDevice.current.name)
        }
    }
}
