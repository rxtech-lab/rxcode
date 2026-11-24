import Foundation

/// This resource ships inside the signed application. Empty pins disable production distribution.
public struct ExtensionProductionTrust: Decodable, Sendable {
    public enum AppleSigning: String, Decodable, Sendable { case adHoc, developerID }
    public let appleSigning: AppleSigning
    public let active: String
    public let backup: String
    public let keys: [String: Data]
    public let revocationKey: Data

    public static let bundled: Self? = {
        guard let url = Bundle.module.url(forResource: "production-trust", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode(Self.self, from: data),
              pins.active != pins.backup, Set(pins.keys.keys) == [pins.active, pins.backup],
              pins.revocationKey.count == 32, pins.keys.values.allSatisfy({ $0.count == 32 }),
              Set(Array(pins.keys.values) + [pins.revocationKey]).count == 3 else { return nil }
        return pins
    }()
}
