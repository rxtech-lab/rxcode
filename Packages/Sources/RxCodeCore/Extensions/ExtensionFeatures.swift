import Foundation

public enum ExtensionFeatures {
    public static var isV2Enabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "RxCodeExtensionAPI2")
        #elseif RXCODE_EXTENSION_RELEASE_GATE
        true
        #else
        false
        #endif
    }
}
