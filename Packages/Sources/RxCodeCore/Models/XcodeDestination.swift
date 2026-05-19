import Foundation

/// A single `xcodebuild` destination — populated either from
/// `xcodebuild -showdestinations` or `xcrun simctl list devices --json`.
///
/// The destination is the structured form of what Xcode shows in its
/// run-destination menu (My Mac, iPhone 16, etc). It serializes to the
/// `-destination` argument via `xcodebuildArgument` and is the source of
/// truth for which launcher path `RunTaskExecutor` uses (macOS `open` vs.
/// `xcrun simctl install/launch`).
public struct XcodeDestination: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case macOS
        case macCatalyst
        case iosSimulator
        case iosDevice
        case tvSimulator
        case tvDevice
        case watchSimulator
        case watchDevice
        case visionSimulator
        case visionDevice
        case other
    }

    public var kind: Kind
    /// Raw platform string as reported by `xcodebuild` (e.g. "macOS",
    /// "iOS Simulator", "iOS"). Used verbatim when building the
    /// `-destination` argument.
    public var platform: String
    public var name: String
    /// Simulator UDID, or device identifier when known. Preferred over
    /// `name` for the `-destination` argument because it's unambiguous.
    public var udid: String?
    /// OS version string for simulators (e.g. "18.0"). Optional.
    public var os: String?
    /// CPU architecture for macOS destinations (e.g. "arm64", "x86_64").
    public var arch: String?
    /// Optional macOS variant (e.g. "Mac Catalyst", "Designed for iPad").
    public var variant: String?

    public init(
        kind: Kind,
        platform: String,
        name: String,
        udid: String? = nil,
        os: String? = nil,
        arch: String? = nil,
        variant: String? = nil
    ) {
        self.kind = kind
        self.platform = platform
        self.name = name
        self.udid = udid
        self.os = os
        self.arch = arch
        self.variant = variant
    }

    public var id: String {
        // UDID is unique per device/simulator; fall back to a composite key
        // when missing so generic destinations (e.g. "Any iOS Device") still
        // get a stable id for SwiftUI list diffing.
        if let udid, !udid.isEmpty { return "\(platform):\(udid)" }
        var parts = [platform, name]
        if let os { parts.append(os) }
        if let arch { parts.append(arch) }
        if let variant { parts.append(variant) }
        return parts.joined(separator: "|")
    }

    /// Build the value passed to `xcodebuild -destination "<value>"`.
    /// Prefers `id=<udid>` when available — it's the only form that
    /// unambiguously targets a single simulator runtime.
    public var xcodebuildArgument: String {
        var parts: [String] = ["platform=\(platform)"]
        if let udid, !udid.isEmpty {
            parts.append("id=\(udid)")
        } else {
            parts.append("name=\(name)")
            if let os, !os.isEmpty { parts.append("OS=\(os)") }
        }
        if let arch, !arch.isEmpty { parts.append("arch=\(arch)") }
        if let variant, !variant.isEmpty { parts.append("variant=\(variant)") }
        return parts.joined(separator: ",")
    }

    /// Human-readable label for menus. Mirrors what Xcode shows.
    public var displayName: String {
        switch kind {
        case .macOS:
            if let variant, !variant.isEmpty { return "\(name) (\(variant))" }
            if let arch, !arch.isEmpty { return "\(name) (\(arch))" }
            return name
        case .iosSimulator, .tvSimulator, .watchSimulator, .visionSimulator:
            if let os, !os.isEmpty { return "\(name) — \(os)" }
            return name
        default:
            return name
        }
    }

    /// Coarse grouping for menu sections.
    public var groupLabel: String {
        switch kind {
        case .macOS: return "macOS"
        case .macCatalyst: return "Mac Catalyst"
        case .iosSimulator: return "iOS Simulators"
        case .iosDevice: return "iOS Devices"
        case .tvSimulator: return "tvOS Simulators"
        case .tvDevice: return "tvOS Devices"
        case .watchSimulator: return "watchOS Simulators"
        case .watchDevice: return "watchOS Devices"
        case .visionSimulator: return "visionOS Simulators"
        case .visionDevice: return "visionOS Devices"
        case .other: return "Other"
        }
    }

    /// Whether `RunTaskExecutor` can actually launch the produced bundle for
    /// this destination. Currently true for macOS and any simulator; false
    /// for physical iOS/tvOS/watchOS/visionOS devices (which require Xcode's
    /// `devicectl` plumbing we don't have yet).
    public var isLaunchable: Bool {
        switch kind {
        case .macOS, .macCatalyst,
             .iosSimulator, .tvSimulator, .watchSimulator, .visionSimulator:
            return true
        case .iosDevice, .tvDevice, .watchDevice, .visionDevice, .other:
            return false
        }
    }
}
