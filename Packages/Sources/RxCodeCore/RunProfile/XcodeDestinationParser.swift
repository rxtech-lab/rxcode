import Foundation

/// Parses `xcodebuild -showdestinations` output into `[XcodeDestination]`.
///
/// The command prints two sections — "Available destinations" and
/// "Ineligible destinations" — each followed by lines like:
///
///     { platform:iOS Simulator, id:ABCD-1234, OS:18.0, name:iPhone 16 }
///
/// We only keep entries from the "Available" section. Each `{ ... }` block
/// is split on `, ` then on `:` to extract key/value pairs.
public enum XcodeDestinationParser {

    public static func parse(_ output: String) -> [XcodeDestination] {
        var results: [XcodeDestination] = []
        var seen = Set<String>()
        var inAvailable = false

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Available destinations") {
                inAvailable = true
                continue
            }
            if line.hasPrefix("Ineligible destinations") {
                inAvailable = false
                continue
            }
            guard inAvailable else { continue }
            guard line.hasPrefix("{"), line.hasSuffix("}") else { continue }

            let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            let pairs = parsePairs(inner)
            guard let platform = pairs["platform"], !platform.isEmpty else { continue }

            let destination = XcodeDestination(
                kind: classify(platform: platform, variant: pairs["variant"]),
                platform: platform,
                name: pairs["name"] ?? platform,
                udid: pairs["id"],
                os: pairs["OS"],
                arch: pairs["arch"],
                variant: pairs["variant"]
            )

            if seen.insert(destination.id).inserted {
                results.append(destination)
            }
        }

        return results
    }

    /// Splits `key:value, key:value` honoring commas-within-values would be
    /// nice, but xcodebuild never emits those. Splitting on `, ` is enough.
    private static func parsePairs(_ inner: String) -> [String: String] {
        var out: [String: String] = [:]
        for chunk in inner.components(separatedBy: ", ") {
            guard let colon = chunk.firstIndex(of: ":") else { continue }
            let key = String(chunk[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(chunk[chunk.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func classify(platform: String, variant: String?) -> XcodeDestination.Kind {
        if let variant, variant == "Mac Catalyst" { return .macCatalyst }
        switch platform {
        case "macOS": return .macOS
        case "iOS Simulator": return .iosSimulator
        case "iOS": return .iosDevice
        case "tvOS Simulator": return .tvSimulator
        case "tvOS": return .tvDevice
        case "watchOS Simulator": return .watchSimulator
        case "watchOS": return .watchDevice
        case "visionOS Simulator": return .visionSimulator
        case "visionOS": return .visionDevice
        default: return .other
        }
    }
}
