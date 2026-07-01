import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// Enumerates this device's usable local IP addresses for raw-interface ICE
/// candidates — the fallback for subnets where mDNS/Bonjour is blocked but the
/// two devices still share a route.
enum NetworkInterfaces {
    /// Non-loopback, non-link-local IPv4/IPv6 literals for up interfaces.
    /// Excludes `169.254.*`, `fe80::*`, loopback, and down interfaces.
    static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0,
                  (flags & Int32(IFF_LOOPBACK)) == 0,
                  let addr = ptr.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            var ip = String(decoding: bytes, as: UTF8.self)
            // Strip the IPv6 scope id ("fe80::1%en0" → "fe80::1") before filtering.
            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
            guard isRoutable(ip) else { continue }
            if !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }

    /// Reject loopback and link-local addresses that can't reach a peer.
    private static func isRoutable(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" { return false }
        if ip.hasPrefix("169.254.") { return false }          // IPv4 link-local
        let lower = ip.lowercased()
        if lower.hasPrefix("fe80:") { return false }           // IPv6 link-local
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            // Unique-local IPv6 is routable within a site — keep it.
        }
        return true
    }
}
