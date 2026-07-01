import Foundation
import Network
import os
#if canImport(Darwin)
import Darwin
#endif

/// A best-effort NAT-PMP (RFC 6886) client used to obtain a reachable public
/// IP:port for WAN-direct candidates.
///
/// It asks the default gateway for its public address and a TCP port mapping to
/// this device's direct-listener port. On a cooperating router (Apple/AirPort,
/// most consumer NAT-PMP/PCP gateways) this yields a `wanMapped` candidate; on a
/// non-cooperating NAT it simply times out and WAN-direct is not offered, leaving
/// the relay to carry the traffic. There is deliberately no UDP hole-punching.
public struct PortMapping: Sendable, Equatable {
    public let publicIP: String
    public let externalPort: UInt16
    public let lifetimeSeconds: UInt32
}

public actor PortMapper {
    private static let natpmpPort: UInt16 = 5351
    private let logger = Logger(subsystem: "com.idealapp.RxCodeSync", category: "PortMapper")

    public init() {}

    /// Request a public address + TCP mapping for `internalPort`. Returns nil on
    /// any failure (no gateway, no NAT-PMP support, timeout).
    public func requestMapping(internalPort: UInt16, lifetime: UInt32 = 3600) async -> PortMapping? {
        guard let gateway = Self.defaultGatewayIPv4() else {
            logger.info("[PortMapper] no default gateway found — WAN-direct unavailable")
            return nil
        }
        guard let publicIP = await sendExternalAddressRequest(gateway: gateway) else {
            logger.info("[PortMapper] gateway \(gateway, privacy: .public) did not answer NAT-PMP — WAN-direct unavailable")
            return nil
        }
        guard let external = await sendMapRequest(gateway: gateway, internalPort: internalPort, lifetime: lifetime) else {
            return nil
        }
        logger.info("[PortMapper] mapped \(internalPort, privacy: .public) → \(publicIP, privacy: .public):\(external.port, privacy: .public) lifetime=\(external.lifetime, privacy: .public)s")
        return PortMapping(publicIP: publicIP, externalPort: external.port, lifetimeSeconds: external.lifetime)
    }

    // MARK: - NAT-PMP requests

    private func sendExternalAddressRequest(gateway: String) async -> String? {
        // [version=0, opcode=0]
        let request = Data([0, 0])
        guard let response = await exchange(gateway: gateway, request: request, minResponse: 12) else { return nil }
        // [ver, op=128, result(2), epoch(4), ip(4)]
        guard response.count >= 12, response[1] == 128 else { return nil }
        let result = UInt16(response[2]) << 8 | UInt16(response[3])
        guard result == 0 else { return nil }
        return "\(response[8]).\(response[9]).\(response[10]).\(response[11])"
    }

    private func sendMapRequest(gateway: String, internalPort: UInt16, lifetime: UInt32) async -> (port: UInt16, lifetime: UInt32)? {
        var request = Data()
        request.append(0)                 // version
        request.append(2)                 // opcode 2 = map TCP
        request.append(contentsOf: [0, 0]) // reserved
        request.append(UInt8(internalPort >> 8)); request.append(UInt8(internalPort & 0xff))
        // Suggested external port = internal port (router may pick another).
        request.append(UInt8(internalPort >> 8)); request.append(UInt8(internalPort & 0xff))
        request.append(UInt8((lifetime >> 24) & 0xff)); request.append(UInt8((lifetime >> 16) & 0xff))
        request.append(UInt8((lifetime >> 8) & 0xff)); request.append(UInt8(lifetime & 0xff))

        guard let response = await exchange(gateway: gateway, request: request, minResponse: 16) else { return nil }
        // [ver, op=130, result(2), epoch(4), internalPort(2), externalPort(2), lifetime(4)]
        guard response.count >= 16, response[1] == 130 else { return nil }
        let result = UInt16(response[2]) << 8 | UInt16(response[3])
        guard result == 0 else { return nil }
        let externalPort = UInt16(response[10]) << 8 | UInt16(response[11])
        let grantedLifetime = UInt32(response[12]) << 24 | UInt32(response[13]) << 16 | UInt32(response[14]) << 8 | UInt32(response[15])
        return (externalPort, grantedLifetime)
    }

    /// Fire a single UDP datagram to the gateway and await one reply (2s cap).
    private func exchange(gateway: String, request: Data, minResponse: Int) async -> Data? {
        guard let port = NWEndpoint.Port(rawValue: Self.natpmpPort) else { return nil }
        let host = NWEndpoint.Host(gateway)
        let connection = NWConnection(host: host, port: port, using: .udp)
        let queue = DispatchQueue(label: "com.idealapp.RxCodeSync.portmapper")

        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let state = ExchangeState()
            connection.stateUpdateHandler = { st in
                if case .ready = st {
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in
                        state.finish(cont: cont, connection: connection, value: (data?.count ?? 0) >= minResponse ? data : nil)
                    }
                } else if case .failed = st {
                    state.finish(cont: cont, connection: connection, value: nil)
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.0) {
                state.finish(cont: cont, connection: connection, value: nil)
            }
        }
    }

    /// Guards single-resume of the exchange continuation across the reply,
    /// failure, and timeout races.
    private final class ExchangeState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func finish(cont: CheckedContinuation<Data?, Never>, connection: NWConnection, value: Data?) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            connection.cancel()
            cont.resume(returning: value)
        }
    }

    // MARK: - Default gateway discovery (sysctl route dump)

#if os(macOS)
    /// Parse the kernel routing table for the IPv4 default route's gateway.
    ///
    /// macOS only: the `<net/route.h>` message layout (`rt_msghdr`, `RTF_*`,
    /// `RTA_*`) isn't exposed in the iOS SDK. That's by design here — the device
    /// that *offers* a WAN candidate (typically the desktop on a home network
    /// with a NAT-PMP router) needs this; the iOS *dialer* just connects to the
    /// advertised public address and never maps a port.
    static func defaultGatewayIPv4() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buffer, &len, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            let base = raw.baseAddress!
            while offset < len {
                let hdr = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self).pointee
                if hdr.rtm_msglen == 0 { break }
                // Default route: gateway flag set and a default (0.0.0.0) destination.
                if (hdr.rtm_flags & RTF_GATEWAY) != 0 {
                    if let gw = gatewayAddress(base: base, msgOffset: offset, addrsMask: hdr.rtm_addrs, msgLen: Int(hdr.rtm_msglen)) {
                        return gw
                    }
                }
                offset += Int(hdr.rtm_msglen)
            }
            return nil
        }
    }

    /// Walk the sockaddrs trailing an rt_msghdr; return the RTA_GATEWAY address if
    /// the destination is the default route (0.0.0.0).
    private static func gatewayAddress(base: UnsafeRawPointer, msgOffset: Int, addrsMask: Int32, msgLen: Int) -> String? {
        var cursor = msgOffset + MemoryLayout<rt_msghdr>.stride
        let end = msgOffset + msgLen
        var isDefaultDestination = false
        var gateway: String?

        // Addresses appear in ascending RTA_* bit order.
        let order: [Int32] = [RTA_DST, RTA_GATEWAY, RTA_NETMASK, RTA_GENMASK, RTA_IFP, RTA_IFA, RTA_AUTHOR, RTA_BRD]
        for bit in order {
            guard (addrsMask & bit) != 0, cursor + MemoryLayout<sockaddr>.size <= end else { continue }
            let sa = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr.self)
            let saLen = Int(sa.pointee.sa_len)
            let advance = saLen == 0 ? 4 : (saLen + 3) & ~3   // round up to 4

            if sa.pointee.sa_family == UInt8(AF_INET) {
                let sin = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr_in.self).pointee
                let ip = ipv4String(sin.sin_addr)
                if bit == RTA_DST {
                    isDefaultDestination = (sin.sin_addr.s_addr == 0)
                } else if bit == RTA_GATEWAY {
                    gateway = ip
                }
            }
            cursor += advance
        }
        return isDefaultDestination ? gateway : nil
    }

    private static func ipv4String(_ addr: in_addr) -> String {
        let n = addr.s_addr   // network byte order
        return "\(n & 0xff).\((n >> 8) & 0xff).\((n >> 16) & 0xff).\((n >> 24) & 0xff)"
    }
#else
    /// iOS: no route-table access. WAN candidates are only ever *offered* by the
    /// peer that can map a port (the desktop); this device dials theirs instead.
    static func defaultGatewayIPv4() -> String? { nil }
#endif
}
