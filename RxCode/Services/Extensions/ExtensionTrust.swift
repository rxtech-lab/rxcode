import Foundation
import RxCodeExtensionDistribution

nonisolated enum ExtensionTrust {
    // Production activation stays gated until the key ceremony pins both release keys.
    static let rxlabPublicKeys = ExtensionProductionTrust.bundled?.keys ?? [:]
    static let revocationPublicKey = ExtensionProductionTrust.bundled?.revocationKey

    static var developerIDSignedKeys: Set<String> {
        ExtensionProductionTrust.bundled?.appleSigning == .developerID ? Set(rxlabPublicKeys.keys) : []
    }

    #if DEBUG
    static let debugKeys = [
        "test-active": Data(base64Encoded: "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=")!,
        "test-backup": Data(base64Encoded: "gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=")!
    ]
    static let debugRevocationKey = Data(base64Encoded: "7UkoxijRwsbq6QM4kFmVYSlZJzpcY/k2NsFGFKyHN9E=")!
    #endif

    static var verificationKeys: [String: Data] {
        #if DEBUG
        rxlabPublicKeys.merging(debugKeys) { trusted, _ in trusted }
        #else
        rxlabPublicKeys
        #endif
    }
}
