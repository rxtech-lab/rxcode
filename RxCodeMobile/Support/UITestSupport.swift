import Foundation

#if DEBUG
/// Parses the UI-test launch arguments and applies the two overrides the UI
/// test harness depends on: pointing the relay at the in-process mock server,
/// and skipping the QR-code pairing flow.
///
/// Entirely inert unless the app is launched with `-uitest-mock`, and compiled
/// only into Debug builds, so it never affects shipping behaviour.
enum UITestSupport {
    /// `true` when the app was launched by the UI test harness.
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-mock")
    }

    /// Value following a `-flag value` pair in the launch arguments.
    static func value(for flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// WebSocket URL of the in-process mock relay server.
    static var relayURL: String? { value(for: "-uitest-relay-url") }

    /// Public-key hex of the deterministic desktop identity the mock impersonates.
    static var desktopPubkeyHex: String? { value(for: "-uitest-desktop-pubkey") }

    /// Rewrites `UserDefaults` before `MobileAppState` reads them, so the relay
    /// URL points at the mock and no pairing persisted by a previous run
    /// survives. Must run as the first statement of `MobileAppState.init()`.
    static func applyDefaultsOverrides() {
        guard isActive else { return }
        let defaults = UserDefaults.standard
        if let relayURL {
            defaults.set(relayURL, forKey: "mobileSync.relayURL")
        }
        // Drop any persisted pairing so `loadPairedDesktops()` starts clean and
        // the synthetic pairing injected afterwards is the only one.
        defaults.removeObject(forKey: MobileAppState.mobilePubkeyKey)
        defaults.removeObject(forKey: MobileAppState.pairedDesktopsKey)
        defaults.removeObject(forKey: MobileAppState.activeDesktopPubkeyKey)
        defaults.removeObject(forKey: MobileAppState.legacyDesktopPubkeyKey)
        defaults.removeObject(forKey: MobileAppState.legacyDesktopNameKey)
    }
}
#else
/// Release-build shim: the UI-test seam does not exist outside Debug builds.
enum UITestSupport {
    static var isActive: Bool { false }
    static func applyDefaultsOverrides() {}
}
#endif
